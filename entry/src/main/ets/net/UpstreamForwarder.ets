/**
 * 上游 DNS 转发器（PRD V5 / V6）
 *
 * 职责：把未命中黑名单的查询转发给上游 DNS，并把应答原样带回。
 *
 * 关键设计（ADR-001）：
 *   1. 单例 UDP socket，复用连接，避免每查询建 socket（AD-1 限流）
 *   2. **事务 ID 重映射**：并发查询可能有相同 ID，改为自增 ID 发出去，收到应答再改回原 ID
 *   3. **必须 protect(socketFd)**：否则转发出去的包会被 TUN 再次捕获，形成回环（AD-1 / V6）
 *   4. 超时返回 null，由调用方转 SERVFAIL（AD-5）
 *
 * ⛔ 本文件依赖 @ohos.*，不参与 node 单元测试（ADR-3 的分层边界）。
 */

import socket from '@ohos.net.socket';
import vpnExtension from '@ohos.net.vpnExtension';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

interface PendingSlot {
  resolve: (v: Uint8Array | null) => void;
  timer: number;
}

export class UpstreamForwarder {
  private udp: socket.UDPSocket | null = null;
  private upstream: string = '';
  private nextId: number = 1;
  private pending: Map<number, PendingSlot> = new Map();
  private protectOk: boolean = false;

  isReady(): boolean {
    return this.udp !== null;
  }

  /** V6 的关键判据：protect 是否成功 */
  isProtected(): boolean {
    return this.protectOk;
  }

  async start(conn: vpnExtension.VpnConnection, upstream: string): Promise<boolean> {
    this.upstream = upstream;
    let udp: socket.UDPSocket;
    try {
      udp = socket.constructUDPSocketInstance();
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`UDP bind failed: code=${err.code} msg=${err.message}`);
      return false;
    }
    this.udp = udp;

    // protect：让转发流量走底层网络，不回环进 TUN
    try {
      const fd: number = await udp.getSocketFd();
      await conn.protect(fd);
      this.protectOk = true;
      Log.info(`Upstream ready upstream=${upstream} socketFd=${fd} protect=OK`);
    } catch (e) {
      const err = e as BusinessError;
      this.protectOk = false;
      Log.error(`protect FAILED: code=${err.code} msg=${err.message}`);
    }

    udp.on('message', (info: socket.SocketMessageInfo) => {
      this.onMessage(info);
    });
    udp.on('error', (err: BusinessError) => {
      Log.error(`UDP socket error: code=${err.code} msg=${err.message}`);
    });
    return true;
  }

  /** 分配一个未被占用的 ID */
  private allocId(): number {
    for (let i = 0; i < 65535; i++) {
      const id: number = this.nextId;
      this.nextId = this.nextId >= 65535 ? 1 : this.nextId + 1;
      if (!this.pending.has(id)) {
        return id;
      }
    }
    return -1;
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    const buf = new Uint8Array(info.message);
    if (buf.length < 12) {
      return;
    }
    const id: number = (buf[0] << 8) | buf[1];
    const slot = this.pending.get(id);
    if (slot === undefined) {
      return;   // 超时后才回来的应答，丢弃
    }
    this.pending.delete(id);
    clearTimeout(slot.timer);
    slot.resolve(buf);
  }

  /**
   * 转发一条 DNS 查询。
   * @param payload 完整 DNS 报文（不含 IP/UDP 头），会被复制，不修改入参
   * @returns 上游应答（事务 ID 已还原），失败/超时返回 null
   */
  async forward(payload: Uint8Array, timeoutMs: number): Promise<Uint8Array | null> {
    const udp = this.udp;
    if (udp === null || payload.length < 12) {
      return null;
    }

    const origId: number = (payload[0] << 8) | payload[1];
    const newId: number = this.allocId();
    if (newId < 0) {
      return null;   // 在途表满
    }

    const out = new Uint8Array(payload.length);
    out.set(payload);
    out[0] = (newId >> 8) & 0xFF;
    out[1] = newId & 0xFF;

    const wait = new Promise<Uint8Array | null>((resolve: (v: Uint8Array | null) => void) => {
      const timer: number = setTimeout(() => {
        this.pending.delete(newId);
        resolve(null);
      }, timeoutMs);
      this.pending.set(newId, { resolve: resolve, timer: timer });
    });

    try {
      const ab: ArrayBuffer = out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
      await udp.send({
        data: ab,
        address: { address: this.upstream, port: 53, family: 1 }
      });
    } catch (e) {
      const err = e as BusinessError;
      Log.error(`forward send failed: code=${err.code} msg=${err.message}`);
      const s = this.pending.get(newId);
      if (s !== undefined) {
        clearTimeout(s.timer);
        this.pending.delete(newId);
      }
      return null;
    }

    const resp = await wait;
    if (resp === null || resp.length < 12) {
      return null;
    }
    // 还原原始事务 ID，客户端才能匹配
    resp[0] = (origId >> 8) & 0xFF;
    resp[1] = origId & 0xFF;
    return resp;
  }

  async stop(): Promise<void> {
    // 先把所有等待中的请求释放，避免调用方挂住
    const slots: PendingSlot[] = [];
    this.pending.forEach((v: PendingSlot) => {
      slots.push(v);
    });
    this.pending.clear();
    for (const s of slots) {
      clearTimeout(s.timer);
      s.resolve(null);
    }
    if (this.udp !== null) {
      try {
        await this.udp.close();
      } catch (e) {
        const err = e as BusinessError;
        Log.error(`UDP close failed: code=${err.code}`);
      }
      this.udp = null;
    }
    this.protectOk = false;
  }
}
