import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import vpnExtension from '@ohos.net.vpnExtension';
import fs from '@ohos.file.fs';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { parseDnsQuery } from '../core/DnsCodec';

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
    let reads = 0;
    let nonDns = 0;
    let dnsHits = 0;
    while (this.running && this.tunFd >= 0) {
      try {
        const n = await fs.read(this.tunFd, buf);
        if (n <= 0) {
          await sleep(10);
          continue;
        }
        reads++;
        const bytes = new Uint8Array(buf, 0, n);

        // 解析统一走 DnsCodec（ADR-2 / AD-3）：纯函数，返回 null 即非 DNS 53
        const q = parseDnsQuery(bytes);
        if (q === null) {
          nonDns++;
          // 诊断：前 10 条非 DNS 包打出头部概要，用于区分「真的没有 DNS」与「解析判错」
          if (nonDns <= 10) {
            const ipVer = (bytes[0] >> 4) & 0x0f;
            let detail = `ipVer=${ipVer} n=${n}`;
            if (ipVer === 4 && n >= 20) {
              const ihl = (bytes[0] & 0x0f) * 4;
              const proto = bytes[9];
              let dp = -1;
              if (proto === 17 && n >= ihl + 4) {
                dp = (bytes[ihl + 2] << 8) | bytes[ihl + 3];
              }
              detail += ` ihl=${ihl} proto=${proto} dstPort=${dp}`;
            } else if (ipVer === 6 && n >= 41) {
              detail += ` nextHeader=${bytes[6]}`;
            }
            Log.info(`VPN skip #${reads} ${detail}`);
          }
          continue;
        }

        dnsHits++;
        Log.info(`VPN DNS(v${q.ipVersion}) #${dnsHits} qname=${q.qname} qtype=${q.qtype} n=${n}`);
        // PoC 行为保持不变：抓到一条即销毁
        await this.stopVpn('dns-captured');
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
    Log.info(`VPN readLoop exit (reads=${reads}, nonDns=${nonDns}, dns=${dnsHits})`);
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
