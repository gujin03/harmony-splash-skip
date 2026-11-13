import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import vpnExtension from '@ohos.net.vpnExtension';
import fs from '@ohos.file.fs';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import {
  parseDnsQuery,
  buildNxDomain,
  buildAddressResponse,
  buildServFail,
  buildResponsePacket
} from '../core/DnsCodec';
import type { DnsQuery } from '../core/DnsCodec';
import { decide, ACTION_BLOCK } from '../core/DomainRules';
import { UpstreamForwarder } from '../net/UpstreamForwarder';
import {
  BLACKLIST,
  WHITELIST,
  RESPONSE_MODE,
  RESPONSE_MODE_ZERO,
  UPSTREAM_DNS,
  UPSTREAM_TIMEOUT_MS,
  MAX_INFLIGHT,
  AUTO_STOP_MS
} from '../config/TargetApps';

/**
 * DNS 拦截主链路（PRD v0.3.0 §4.3 四级闭环 / ADR-001）
 *
 * ① 握手：createVpnConnection → create → fd
 * ② 收包：fs.read 循环，EAGAIN 重试
 * ③ 判别：parseDnsQuery 纯函数，返回 null 即非 DNS 53
 * ④ 动作：命中黑名单 → 构造应答；未命中 → 转发上游
 *
 * ⭐ AD-1：readLoop 内**不允许 await 网络响应**。
 *    读循环只做「读 → 解码 → 派发」，转发与回写都在别的异步任务里；
 *    回写统一走 writeQueue 串行，因为并发写同一 fd 的顺序不可依赖。
 */

const VPN_ADDRESS4: string = '10.0.0.2';
const VPN_ADDRESS6: string = 'fd00::2';
const VPN_DNS4: string = '10.0.0.1';
const VPN_DNS6: string = 'fd00::1';
const EAGAIN: number = 13900010;
const MAX_WRITE_QUEUE: number = 256;
const READ_BUF_SIZE: number = 4096;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

export default class SkipVpnExtension extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private forwarder: UpstreamForwarder | null = null;
  private tunFd: number = -1;
  private running: boolean = false;
  private stopTimer: number = -1;

  // 写回队列（AD-1：串行写回）
  private writeQueue: Array<Uint8Array> = [];
  private writing: boolean = false;

  // 统计
  private reads: number = 0;
  private nonDns: number = 0;
  private dnsHits: number = 0;
  private blocked: number = 0;
  private fwdOk: number = 0;
  private fwdFail: number = 0;
  private overload: number = 0;
  private inflight: number = 0;
  private written: number = 0;
  private writeErr: number = 0;
  private dropped: number = 0;
  private dnsLikeFail: number = 0;

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
        // 显式把 DNS 服务器地址路由到 TUN：仅靠 dnsAddresses 不足以让流量进来
        routes: [
          {
            interface: '',
            destination: { address: { address: VPN_DNS4, family: 1 }, prefixLength: 32 },
            gateway: { address: '0.0.0.0', family: 1, port: 0 },
            hasGateway: false,
            isDefaultRoute: false,
            isExcludedRoute: false
          },
          {
            interface: '',
            destination: { address: { address: VPN_DNS6, family: 2 }, prefixLength: 128 },
            gateway: { address: '::', family: 2, port: 0 },
            hasGateway: false,
            isDefaultRoute: false,
            isExcludedRoute: false
          },
        ],
        dnsAddresses: [VPN_DNS4, VPN_DNS6],
        mtu: 1500,
        isIPv4Accepted: true,
        isIPv6Accepted: true,
        isBlocking: false
      };
      this.tunFd = await this.conn.create(config);
      Log.info(`VPN created fd=${this.tunFd}`);

      // 先起转发器，再进读循环：否则首批查询会在没有上游时全部 SERVFAIL
      const fwd = new UpstreamForwarder();
      const ok: boolean = await fwd.start(this.conn, UPSTREAM_DNS);
      this.forwarder = ok ? fwd : null;
      if (!ok) {
        Log.error('forwarder start failed — 未命中查询将全部返回 SERVFAIL');
      }
      Log.info(`mode=${RESPONSE_MODE} upstream=${UPSTREAM_DNS} protect=${fwd.isProtected()}`);

      this.readLoop();
      this.stopTimer = setTimeout(() => {
        this.stopVpn('auto-timeout');
      }, AUTO_STOP_MS);
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`VPN create failed: code=${err.code} msg=${err.message}`);
    }
  }

  /** 读循环：只读 → 解码 → 派发，绝不等待网络（AD-1） */
  private async readLoop(): Promise<void> {
    this.running = true;
    const buf = new ArrayBuffer(READ_BUF_SIZE);
    while (this.running && this.tunFd >= 0) {
      try {
        const n = await fs.read(this.tunFd, buf);
        if (n <= 0) {
          await sleep(10);
          continue;
        }
        this.reads++;
        const view = new Uint8Array(buf, 0, n);
        const q = parseDnsQuery(view);
        if (q === null) {
          this.nonDns++;
          // 关键诊断：区分「没有 DNS 包」与「有 DNS 包但解析失败」
          {
            const iv = (view[0] >> 4) & 0x0f;
            let p: number = -1;
            let d: number = -1;
            if (iv === 4 && n >= 24) {
              const ihl2 = (view[0] & 0x0f) * 4;
              p = view[9];
              if (n >= ihl2 + 4) {
                d = (view[ihl2 + 2] << 8) | view[ihl2 + 3];
              }
            } else if (iv === 6 && n >= 44 && view[6] === 17) {
              p = 17;
              d = (view[42] << 8) | view[43];
            }
            if (p === 17 && d === 53) {
              this.dnsLikeFail++;
              Log.error(`!! DNS-like parse FAIL v${iv} n=${n} (dnsLikeFail=${this.dnsLikeFail})`);
            }
          }
          if (this.nonDns <= 24) {
            const ipVer = (view[0] >> 4) & 0x0f;
            let detail = `v${ipVer} n=${n}`;
            if (ipVer === 4 && n >= 20) {
              const ihl = (view[0] & 0x0f) * 4;
              const proto = view[9];
              let dp = -1;
              if (n >= ihl + 4) {
                dp = (view[ihl + 2] << 8) | view[ihl + 3];
              }
              detail += ` ${view[12]}.${view[13]}.${view[14]}.${view[15]}>` +
                `${view[16]}.${view[17]}.${view[18]}.${view[19]} proto=${proto} dp=${dp}`;
            } else if (ipVer === 6 && n >= 40) {
              let dp = -1;
              // 仅当 nextHeader 直接是 UDP 时端口才可读
              if (view[6] === 17 && n >= 44) {
                dp = (view[42] << 8) | view[43];
              }
              detail += ` nh=${view[6]} dp=${dp} dstTail=${view[36]}.${view[37]}.${view[38]}.${view[39]}`;
            }
            Log.info(`VPN skip #${this.reads} ${detail}`);
          }
          continue;
        }

        this.dnsHits++;
        // ⚠️ buf 会被下一次 read 覆盖，必须先拷贝再交给异步处理
        const raw = new Uint8Array(n);
        raw.set(view);
        this.dispatch(q, raw);
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
    Log.info(`VPN readLoop exit (reads=${this.reads}, nonDns=${this.nonDns}, dns=${this.dnsHits})`);
  }

  /** 派发：同步返回、内部异步，不阻塞读循环（AD-1） */
  private dispatch(q: DnsQuery, raw: Uint8Array): void {
    const action: string = decide(q.qname, WHITELIST, BLACKLIST);

    if (action === ACTION_BLOCK) {
      this.blocked++;
      if (this.blocked <= 30) {
        Log.info(`BLOCK ${q.qname} qt=${q.qtype} mode=${RESPONSE_MODE}`);
      }
      const dns = RESPONSE_MODE === RESPONSE_MODE_ZERO
        ? buildAddressResponse(raw, q, [0, 0, 0, 0])
        : buildNxDomain(raw, q);
      this.enqueueWrite(buildResponsePacket(raw, q, dns));
      return;
    }

    // 未命中：转发上游
    if (this.inflight >= MAX_INFLIGHT) {
      this.overload++;
      Log.warn(`overload inflight=${this.inflight} qname=${q.qname} -> SERVFAIL`);
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
      return;
    }
    const fwd = this.forwarder;
    if (fwd === null || !fwd.isReady()) {
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
      return;
    }

    this.inflight++;
    const payload: Uint8Array = raw.slice(q.dnsOffset, q.dnsEnd);
    fwd.forward(payload, UPSTREAM_TIMEOUT_MS).then((resp: Uint8Array | null) => {
      this.inflight--;
      if (resp === null) {
        this.fwdFail++;
        if (this.fwdFail <= 10) {
          Log.warn(`FWD-FAIL ${q.qname} qt=${q.qtype} -> SERVFAIL`);
        }
        this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
        return;
      }
      this.fwdOk++;
      if (this.fwdOk <= 20) {
        Log.info(`FWD ${q.qname} qt=${q.qtype} len=${resp.length}`);
      }
      this.enqueueWrite(buildResponsePacket(raw, q, resp));
    }).catch((e: BusinessError) => {
      this.inflight--;
      this.fwdFail++;
      Log.error(`forward callback error: code=${e.code} msg=${e.message}`);
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
    });
  }

  private enqueueWrite(pkt: Uint8Array): void {
    if (this.writeQueue.length >= MAX_WRITE_QUEUE) {
      this.dropped++;
      return;
    }
    this.writeQueue.push(pkt);
    if (!this.writing) {
      this.drainWrites();
    }
  }

  /** 串行写回 TUN：并发写同一 fd 的顺序不可依赖（AD-1） */
  private async drainWrites(): Promise<void> {
    if (this.writing) {
      return;
    }
    this.writing = true;
    while (this.writeQueue.length > 0 && this.tunFd >= 0) {
      const pkt = this.writeQueue.shift();
      if (pkt === undefined) {
        break;
      }
      try {
        const ab: ArrayBuffer = pkt.buffer.slice(pkt.byteOffset, pkt.byteOffset + pkt.byteLength);
        await fs.write(this.tunFd, ab);
        this.written++;
      } catch (e) {
        const err = e as BusinessError;
        this.writeErr++;
        if (this.writeErr <= 3) {
          Log.error(`tun write failed: code=${err.code} msg=${err.message}`);
        }
      }
    }
    this.writing = false;
  }

  private async stopVpn(reason: string): Promise<void> {
    if (!this.conn) {
      return;
    }
    this.running = false;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    const fwd = this.forwarder;
    if (fwd !== null) {
      await fwd.stop();
      this.forwarder = null;
    }
    try {
      await this.conn.destroy();
      Log.info('VPN destroyed');
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`VPN destroy failed: code=${err.code}`);
    }
    this.conn = null;
    this.tunFd = -1;
    Log.info(`STATS (${reason}) dns=${this.dnsHits} block=${this.blocked} ` +
      `fwdOk=${this.fwdOk} fwdFail=${this.fwdFail} overload=${this.overload} ` +
      `written=${this.written} writeErr=${this.writeErr} dropped=${this.dropped} dnsLikeFail=${this.dnsLikeFail} ` +
      `inflight=${this.inflight} queue=${this.writeQueue.length}`);
  }

  onDestroy(): void {
    Log.info('VPN onDestroy');
    this.stopVpn('onDestroy');
  }
}
