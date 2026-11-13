import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import vpnExtension from '@ohos.net.vpnExtension';
import fs from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import {
  parseDnsQuery,
  buildNxDomain,
  buildAddressResponse,
  buildAaaaResponse,
  buildServFail,
  buildResponsePacket,
  QTYPE_AAAA
} from '../core/DnsCodec';
import type { DnsQuery } from '../core/DnsCodec';
import { ACTION_ALLOW, ACTION_BLOCK } from '../core/DomainRules';
import { DiagStats, ACTION_BLOCK as DIAG_BLOCK, ACTION_FWD, ACTION_FAIL } from '../core/DiagStats';
import { UpstreamForwarder } from '../net/UpstreamForwarder';
import {
  RESPONSE_MODE,
  RESPONSE_MODE_ZERO,
  UPSTREAM_DNS,
  UPSTREAM_TIMEOUT_MS,
  MAX_INFLIGHT
} from '../config/TargetApps';
import { RuleStore } from '../config/RuleStore';
import type { Decision } from '../config/RuleStore';
import { writeVpnState } from '../common/VpnState';

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
const NOTIFY_ID: number = 1001;
const NOTIFY_UPDATE_EVERY: number = 5;   // 每 N 次拦截更新一次通知，避免刷太频
const DIAG_WRITE_MS: number = 2000;      // 诊断快照最小写盘间隔
const DIAG_FILE: string = '/diag.json';
const BUNDLE_NAME: string = 'com.liuqi.splashskip';
const ENTRY_ABILITY: string = 'EntryAbility';
// 空闲降频（NFR CPU/功耗）：连续 EAGAIN 时 10 → 100ms 退避，读到包立即回到 10ms
const IDLE_MIN_MS: number = 10;
const IDLE_STEP_MS: number = 10;
const IDLE_MAX_MS: number = 100;

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
  private rules: RuleStore | null = null;

  // 写回队列（AD-1：串行写回）
  private writeQueue: Array<Uint8Array> = [];
  private writing: boolean = false;

  // 统计
  private reads: number = 0;
  private nonDns: number = 0;
  private stats: DiagStats = new DiagStats();
  private inflight: number = 0;
  private dropped: number = 0;
  private dnsLikeFail: number = 0;
  private blockLogged: number = 0;
  private notifyOk: boolean = false;
  private lastNotifiedAt: number = -1;
  private lastDiagAt: number = 0;

  onCreate(want: Want): void {
    Log.info('VPN onCreate');
    // 规则以沙箱文件为准：装完机后改 rules.json 即可热更新，不必重新编译
    this.rules = new RuleStore(this.context.filesDir);
    this.rules.init();
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

      this.publishNotification();
      this.readLoop();
      writeVpnState(this.context.filesDir, {
        running: true, startedAt: Date.now(), reason: 'running', errCode: 0
      });
      // ⛔ 不再设 2 分钟 AUTO_STOP：§10-3 要求连续 24h 不自动断开，
      //    且扩展进程的 setTimeout 实测根本不触发（旧注释见 Index.ets）。
      //    停止只走「应用内按钮」或「通知栏停止按钮」两条明确入口。
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`VPN create failed: code=${err.code} msg=${err.message}`);
      writeVpnState(this.context.filesDir, {
        running: false, startedAt: 0, reason: 'create-failed', errCode: err.code
      });
    }
  }

  /** 读循环：只读 → 解码 → 派发，绝不等待网络（AD-1） */
  private async readLoop(): Promise<void> {
    this.running = true;
    const buf = new ArrayBuffer(READ_BUF_SIZE);
    let idleMs: number = IDLE_MIN_MS;
    while (this.running && this.tunFd >= 0) {
      try {
        const n = await fs.read(this.tunFd, buf);
        if (n <= 0) {
          await sleep(idleMs);
          idleMs = Math.min(idleMs + IDLE_STEP_MS, IDLE_MAX_MS);
          continue;
        }
        idleMs = IDLE_MIN_MS;   // 有包立刻恢复灵敏，不牺牲拦截时延
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

        this.stats.bumpDns();
        // ⚠️ buf 会被下一次 read 覆盖，必须先拷贝再交给异步处理
        const raw = new Uint8Array(n);
        raw.set(view);
        this.dispatch(q, raw);
      } catch (e) {
        const err = e as BusinessError;
        if (err.code === EAGAIN) {
          await sleep(idleMs);
          idleMs = Math.min(idleMs + IDLE_STEP_MS, IDLE_MAX_MS);
          continue;
        }
        Log.error(`VPN read failed: code=${err.code} msg=${err.message}`);
        break;
      }
    }
    Log.info(`VPN readLoop exit (reads=${this.reads}, nonDns=${this.nonDns}, dns=${this.stats.getDns()})`);
  }

  /** 派发：同步返回、内部异步，不阻塞读循环（AD-1） */
  private dispatch(q: DnsQuery, raw: Uint8Array): void {
    let action: string = ACTION_ALLOW;
    let reason: string = 'no-rule-store';
    if (this.rules !== null) {
      this.rules.refreshIfChanged();   // FR-3.5：改 rules.json 后下一次查询即生效
      const d: Decision = this.rules.decide(q.qname);
      action = d.action;
      reason = d.reason;
    }
    const now: number = Date.now();
    if (reason === 'session-allow') {
      Log.info(`SESSION-ALLOW ${q.qname}（FR-8.3 本次会话放行）`);
    }

    if (action === ACTION_BLOCK) {
      this.stats.record(now, q.qname, DIAG_BLOCK, reason, q.ipVersion);
      this.blockLogged++;
      const ansTag: string = q.qtype === QTYPE_AAAA ? 'AAAA(::)' : 'A(0.0.0.0)';
      if (this.blockLogged <= 30) {
        Log.info(`BLOCK ${q.qname} qt=${q.qtype} ans=${ansTag} rule=${reason} mode=${RESPONSE_MODE}`);
      }
      let dns: Uint8Array;
      if (RESPONSE_MODE !== RESPONSE_MODE_ZERO) {
        dns = buildNxDomain(raw, q);
      } else if (q.qtype === QTYPE_AAAA) {
        dns = buildAaaaResponse(raw, q);   // FR-2.4：IPv6 查询回 :: ，不回 A 记录
      } else {
        dns = buildAddressResponse(raw, q, [0, 0, 0, 0]);
      }
      this.enqueueWrite(buildResponsePacket(raw, q, dns));
      if (this.stats.getBlock() - this.lastNotifiedAt >= NOTIFY_UPDATE_EVERY) {
        this.lastNotifiedAt = this.stats.getBlock();
        this.publishNotification();
      }
      this.writeDiagThrottled();
      return;
    }

    // 未命中：转发上游
    if (this.inflight >= MAX_INFLIGHT) {
      this.stats.bumpOverload();
      this.stats.record(now, q.qname, ACTION_FAIL, 'overload', q.ipVersion);
      Log.warn(`overload inflight=${this.inflight} qname=${q.qname} -> SERVFAIL`);
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
      this.writeDiagThrottled();
      return;
    }
    const fwd = this.forwarder;
    if (fwd === null || !fwd.isReady()) {
      this.stats.record(now, q.qname, ACTION_FAIL, 'no-forwarder', q.ipVersion);
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
      this.writeDiagThrottled();
      return;
    }

    this.inflight++;
    const payload: Uint8Array = raw.slice(q.dnsOffset, q.dnsEnd);
    fwd.forward(payload, UPSTREAM_TIMEOUT_MS).then((resp: Uint8Array | null) => {
      this.inflight--;
      if (resp === null) {
        this.stats.record(Date.now(), q.qname, ACTION_FAIL, 'timeout', q.ipVersion);
        if (this.stats.getFwdFail() <= 10) {
          Log.warn(`FWD-FAIL ${q.qname} qt=${q.qtype} -> SERVFAIL`);
        }
        this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
        this.writeDiagThrottled();
        return;
      }
      this.stats.record(Date.now(), q.qname, ACTION_FWD, 'upstream', q.ipVersion);
      if (this.stats.getFwdOk() <= 20) {
        Log.info(`FWD ${q.qname} qt=${q.qtype} len=${resp.length}`);
      }
      this.enqueueWrite(buildResponsePacket(raw, q, resp));
      this.writeDiagThrottled();
    }).catch((e: BusinessError) => {
      this.inflight--;
      this.stats.record(Date.now(), q.qname, ACTION_FAIL, 'cb-error', q.ipVersion);
      Log.error(`forward callback error: code=${e.code} msg=${e.message}`);
      this.enqueueWrite(buildResponsePacket(raw, q, buildServFail(raw, q)));
      this.writeDiagThrottled();
    });
  }

  /**
   * 节流写诊断快照到应用沙箱，供 UI 跨进程读取（FR-5）。
   * 扩展进程与 UI 进程内存不共享，只能用文件传递；2 秒节流避免频繁写盘。
   */
  private writeDiagThrottled(): void {
    const now: number = Date.now();
    if (now - this.lastDiagAt < DIAG_WRITE_MS) {
      return;
    }
    this.lastDiagAt = now;
    const path: string = this.context.filesDir + DIAG_FILE;
    const snap: string = JSON.stringify(this.stats.snapshot(now));
    // 无 fs.writeFile，用 open/write/close；文件仅约 2KB 且 2 秒节流，同步写代价可忽略
    let file: fs.File | null = null;
    try {
      const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
      file = fs.openSync(path, mode);
      fs.writeSync(file.fd, snap);
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`write diag failed: code=${err.code} msg=${err.message}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败无需处理
        }
      }
    }
  }

  /** 常驻通知：显示运行状态与统计（FR-6.1 / FR-6.2） */
  private async publishNotification(): Promise<void> {
    try {
      // FR-6.1：通知栏「停止拦截」按钮。WantAgent 指向 EntryAbility 并带 stop_vpn 参数，
      // 由 EntryAbility.onCreate / onNewWant 直接调 stopVpnExtensionAbility，无需用户再点一次。
      let buttons: Array<notificationManager.NotificationActionButton> = [];
      try {
        const agent = await wantAgent.getWantAgent({
          wants: [{
            bundleName: BUNDLE_NAME,
            abilityName: ENTRY_ABILITY,
            parameters: { action: 'stop_vpn' }
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        buttons = [{ title: '停止拦截', wantAgent: agent }];
      } catch (e) {
        const ae = e as BusinessError;
        Log.error(`build stop WantAgent failed: code=${ae.code}`);
      }
      const request: notificationManager.NotificationRequest = {
        id: NOTIFY_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '开屏广告拦截 · 运行中',
            text: `已拦截 ${this.stats.getBlock()} · 转发 ${this.stats.getFwdOk()} · 失败 ${this.stats.getFwdFail()}`,
            additionalText: '点「停止拦截」立即关闭'
          }
        },
        isOngoing: true,
        actionButtons: buttons
      };
      await notificationManager.publish(request);
      if (!this.notifyOk) {
        this.notifyOk = true;
        Log.info('notification published');
      }
    } catch (e) {
      const err = e as BusinessError;
      if (this.notifyOk || this.stats.getBlock() === 0) {
        Log.error(`publish notification failed: code=${err.code} msg=${err.message}`);
      }
      this.notifyOk = false;
    }
  }

  private async cancelNotification(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFY_ID);
    } catch (e) {
      const err = e as BusinessError;
      // 1600007 = 通知不存在，属正常（可能已被取消过）
      if (err.code !== 1600007) {
        Log.error(`cancel notification failed: code=${err.code}`);
      }
    }
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
        this.stats.bumpWritten();
      } catch (e) {
        const err = e as BusinessError;
        this.stats.bumpWriteErr();
        Log.error(`tun write failed: code=${err.code} msg=${err.message}`);
      }
    }
    this.writing = false;
  }

  /**
   * ⛔ 必须保持同步（无 await）：onDestroy 返回后进程随时被系统回收。
   *
   * 真机 2026-11-14 01:06 实测：旧实现在 `await fwd.stop()`（内部 await udp.close()）挂住，
   * 点通知栏「停止拦截」后只看到 onDestroy 与 readLoop exit，之后的
   * vpn_state.json 仍写 running=true、通知残留、conn.destroy 没执行 —— 首页显示假的「运行中」。
   * 现在把「状态／通知／统计」全部同步做完，网络资源改为 fire-and-forget。
   */
  private stopVpn(reason: string): void {
    this.running = false;
    this.writeQueue = [];
    this.tunFd = -1;

    // ① 同步收尾：跨进程状态、临时放行、通知、最终统计
    writeVpnState(this.context.filesDir, {
      running: false, startedAt: 0, reason: reason, errCode: 0
    });
    if (this.rules !== null) {
      this.rules.clearSessionAllow();   // FR-8.3：临时放行只在本次会话有效
    }
    this.cancelNotification();
    const snap = this.stats.snapshot(Date.now());
    Log.info(`STATS (${reason}) dns=${snap.dns} block=${snap.block} ` +
      `fwdOk=${snap.fwdOk} fwdFail=${snap.fwdFail} overload=${snap.overload} ` +
      `written=${snap.written} writeErr=${snap.writeErr} dropped=${this.dropped} dnsLikeFail=${this.dnsLikeFail} ` +
      `inflight=${this.inflight} queue=${this.writeQueue.length}`);
    this.lastDiagAt = 0;
    this.writeDiagThrottled();

    // ② 网络资源清理：互不阻塞，失败只记日志
    const fwd = this.forwarder;
    this.forwarder = null;
    if (fwd !== null) {
      fwd.stop().catch((e: BusinessError) => {
        Log.error(`forwarder stop failed: code=${e.code}`);
      });
    }
    const conn = this.conn;
    this.conn = null;
    if (conn !== null) {
      conn.destroy().then(() => {
        Log.info('VPN destroyed');
      }).catch((e: BusinessError) => {
        Log.error(`VPN destroy failed: code=${e.code}`);
      });
    }
  }

  onDestroy(): void {
    Log.info('VPN onDestroy');
    // 同步发起取消，不 await：进程会被系统回收，await 可能等不到
    notificationManager.cancel(NOTIFY_ID).catch((e: BusinessError) => {
      Log.error(`cancel notify failed: code=${e.code}`);
    });
    this.stopVpn('onDestroy');
  }
}
