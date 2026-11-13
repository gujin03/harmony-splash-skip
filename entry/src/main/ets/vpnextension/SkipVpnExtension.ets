import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import vpnExtension from '@ohos.net.vpnExtension';
import fs from '@ohos.file.fs';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/**
 * VPN PoC v3：同时接管 IPv4 / IPv6 的 DNS
 *   - 手机 Wi-Fi 有 IPv6 时，系统优先用 IPv6 DNS，只配 IPv4 抓不到查询
 *   - 配置 fd00::2/64 + fd00::1，并解析 IPv6 的 UDP 53
 *   - 抓到一条 DNS 即销毁 VPN，兜底 30 秒
 */
const VPN_ADDRESS4: string = '10.0.0.2';
const VPN_ADDRESS6: string = 'fd00::2';
const VPN_DNS4: string = '10.0.0.1';
const VPN_DNS6: string = 'fd00::1';
const AUTO_STOP_MS: number = 30000;
const EAGAIN: number = 13900010;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function parseQname(bytes: Uint8Array, off: number): string {
  const labels: string[] = [];
  let i = off;
  while (i < bytes.length && bytes[i] !== 0) {
    const len = bytes[i];
    i++;
    let s = '';
    for (let j = 0; j < len && i < bytes.length; j++) {
      s += String.fromCharCode(bytes[i]);
      i++;
    }
    labels.push(s);
  }
  return labels.join('.');
}


function ipv6UdpOffset(bytes: Uint8Array, n: number): number {
  let off = 40;
  let nh = bytes[6];
  let guard = 0;
  while (guard < 8) {
    guard++;
    if (nh === 17) {
      return off;
    }
    if (nh === 0 || nh === 43 || nh === 60) {
      if (off + 2 > n) {
        return -1;
      }
      const len = (bytes[off + 1] + 1) * 8;
      nh = bytes[off];
      off += len;
      continue;
    }
    if (nh === 44) {
      if (off + 8 > n) {
        return -1;
      }
      nh = bytes[off];
      off += 8;
      continue;
    }
    return -1;
  }
  return -1;
}

export default class SkipVpnExtension extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private running: boolean = false;
  private stopTimer: number = -1;

  onCreate(want: Want): void {
    Log.info('VPN onCreate');
    this.startVpn();
  }

  private async startVpn(): Promise<void> {
    try {
      this.conn = vpnExtension.createVpnConnection(this.context);
      const config: vpnExtension.VpnConfig = {
        addresses: [
          { address: { address: VPN_ADDRESS4 }, prefixLength: 24 },
          { address: { address: VPN_ADDRESS6 }, prefixLength: 64 }
        ],
        dnsAddresses: [VPN_DNS4, VPN_DNS6],
        mtu: 1500,
        isIPv4Accepted: true,
        isIPv6Accepted: true,
        isBlocking: false
      };
      this.tunFd = await this.conn.create(config);
      Log.info(`VPN created fd=${this.tunFd}`);
      this.readLoop();
      this.stopTimer = setTimeout(() => {
        this.stopVpn('auto-timeout');
      }, AUTO_STOP_MS);
    } catch (e) {
      Log.error(`VPN create failed: ${JSON.stringify(e)}`);
    }
  }

  private async readLoop(): Promise<void> {
    this.running = true;
    const buf = new ArrayBuffer(2048);
    let count = 0;
    let ipv4 = 0;
    let ipv6 = 0;
    let dnsHits = 0;
    while (this.running && this.tunFd >= 0) {
      try {
        const n = await fs.read(this.tunFd, buf);
        if (n <= 0) {
          await sleep(10);
          continue;
        }
        count++;
        const bytes = new Uint8Array(buf, 0, n);
        const ipVer = (bytes[0] >> 4) & 0x0f;

        if (ipVer === 4 && n >= 28) {
          ipv4++;
          const ihl = (bytes[0] & 0x0f) * 4;
          if (bytes[9] !== 17 || n < ihl + 8) {
            continue;
          }
          const dstPort = (bytes[ihl + 2] << 8) | bytes[ihl + 3];
          if (dstPort !== 53) {
            if (ipv4 <= 3) {
              Log.info(`VPN v4 #${count} udp dstPort=${dstPort}`);
            }
            continue;
          }
          const qname = parseQname(bytes, ihl + 8 + 12);
          dnsHits++;
          Log.info(`VPN DNS(v4) #${dnsHits} qname=${qname} n=${n}`);
          if (dnsHits >= 1) {
            await this.stopVpn('dns-captured');
          }
          continue;
        }

        if (ipVer === 6 && n >= 48) {
          ipv6++;
          const udpOff = ipv6UdpOffset(bytes, n);
          if (udpOff < 0 || n < udpOff + 8) {
            if (ipv6 <= 3) {
              Log.info(`VPN v6 #${count} nextHeader=${bytes[6]} (no UDP)`);
            }
            continue;
          }
          const dstPort = (bytes[udpOff + 2] << 8) | bytes[udpOff + 3];
          if (dstPort !== 53) {
            if (ipv6 <= 3) {
              Log.info(`VPN v6 #${count} udp dstPort=${dstPort}`);
            }
            continue;
          }
          const qname = parseQname(bytes, udpOff + 8 + 12);
          dnsHits++;
          Log.info(`VPN DNS(v6) #${dnsHits} qname=${qname} n=${n}`);
          if (dnsHits >= 1) {
            await this.stopVpn('dns-captured');
          }
          continue;
        }

        if (count <= 3) {
          Log.info(`VPN skip #${count} n=${n} ipVer=${ipVer}`);
        }
      } catch (e) {
        const err = e as BusinessError;
        if (err.code === EAGAIN) {
          await sleep(10);
          continue;
        }
        Log.error(`VPN read failed: code=${err.code} msg=${err.message}`);
        break;
      }
    }
    Log.info(`VPN readLoop exit (reads=${count}, v4=${ipv4}, v6=${ipv6}, dns=${dnsHits})`);
  }

  private async stopVpn(reason: string): Promise<void> {
    if (!this.conn) {
      return;
    }
    Log.info(`VPN stopping (${reason})`);
    this.running = false;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    try {
      await this.conn.destroy();
      Log.info('VPN destroyed');
    } catch (e) {
      Log.error(`VPN destroy failed: ${JSON.stringify(e)}`);
    }
    this.conn = null;
    this.tunFd = -1;
  }

  onDestroy(): void {
    Log.info('VPN onDestroy');
    this.stopVpn('onDestroy');
  }
}
