/**
 * DNS 报文编解码（纯函数）
 *
 * 契约见 docs/ADR-001-DNS拦截架构决策.md（AD-2 编解码边界 / AD-3 可测性分层）
 *
 * ⛔ 本文件禁止：
 *   1. import 任何 `@ohos.*`（否则无法在本机 node 上跑测试）
 *   2. 打日志、读时间、持有可变状态
 *   3. import 项目内其他模块（node 的 type stripping 要求核心模块自包含）
 *   4. 使用 enum / namespace / 参数属性 / 装饰器（node strip 不支持）
 *
 * 输入输出只看字节与纯数据，所有失败一律返回 null，不抛异常。
 */

export interface DnsQuery {
  ipVersion: number;      // 4 | 6
  transId: number;        // DNS 事务 ID
  qname: string;          // 已转小写、无末尾点
  qtype: number;          // 1 = A | 28 = AAAA
  qclass: number;         // 1 = IN
  dnsOffset: number;      // DNS 报文在包内的起点
  questionEnd: number;    // Question 段结束位置（不含）
  udpOffset: number;      // UDP 头在包内的偏移
  ipHeaderLen: number;    // IPv4 = IHL，IPv6 = 40
}

interface NameParse {
  name: string;
  end: number;        // QNAME 之后第一个字节的位置（%的后续字段从这里开始）
  ok: boolean;
}

const PROTO_UDP: number = 17;
const DNS_PORT: number = 53;
const MAX_NAME_JUMPS: number = 8;
const MAX_LABELS: number = 128;

// DNS Header flags
const FLAG_QR: number = 0x8000;
const FLAG_RA: number = 0x0080;
const FLAG_RCODE_MASK: number = 0x000F;

export const RCODE_NOERROR: number = 0;
export const RCODE_SERVFAIL: number = 2;
export const RCODE_NXDOMAIN: number = 3;

export const QTYPE_A: number = 1;
export const QTYPE_AAAA: number = 28;

// ---------------------------------------------------------------- IP 层解析

/** 跳过 IPv6 扩展头链，返回 UDP 头偏移；找不到返回 -1 */
function ipv6UdpOffset(bytes: Uint8Array, n: number): number {
  let off: number = 40;
  let nh: number = bytes[6];
  let guard: number = 0;
  while (guard < 8) {
    guard++;
    if (nh === PROTO_UDP) {
      return off;
    }
    if (nh === 0 || nh === 43 || nh === 60) {
      if (off + 2 > n) {
        return -1;
      }
      const len: number = (bytes[off + 1] + 1) * 8;
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

// ------------------------------------------------------------ DNS 名字解析

/** 读取 QNAME，支持压缩指针（0xC0），设跳数与标签数上限防环 */
function readName(bytes: Uint8Array, start: number, limit: number): NameParse {
  const labels: string[] = [];
  let pos: number = start;
  let resume: number = -1;
  let jumps: number = 0;

  while (true) {
    if (pos >= limit) {
      return { name: '', end: start, ok: false };
    }
    const len: number = bytes[pos];
    if (len === 0) {
      pos++;
      const end: number = resume >= 0 ? resume : pos;
      return { name: labels.join('.').toLowerCase(), end: end, ok: true };
    }
    // 压缩指针：高两位 11
    if ((len & 0xC0) === 0xC0) {
      if (pos + 1 >= limit) {
        return { name: '', end: start, ok: false };
      }
      const ptr: number = ((len & 0x3F) << 8) | bytes[pos + 1];
      if (resume < 0) {
        resume = pos + 2;
      }
      jumps++;
      if (jumps > MAX_NAME_JUMPS || ptr >= limit) {
        return { name: '', end: start, ok: false };
      }
      pos = ptr;
      continue;
    }
    // 保留位非 0，非法
    if ((len & 0xC0) !== 0) {
      return { name: '', end: start, ok: false };
    }
    pos++;
    if (pos + len > limit) {
      return { name: '', end: start, ok: false };
    }
    let s: string = '';
    for (let i = 0; i < len; i++) {
      s += String.fromCharCode(bytes[pos + i]);
    }
    labels.push(s);
    pos += len;
    if (labels.length > MAX_LABELS) {
      return { name: '', end: start, ok: false };
    }
  }
}

// ---------------------------------------------------------------- 对外解析

/**
 * 从完整的 IP 包中解析 DNS 查询。
 * 不是 UDP 53 / 报文非法 / 无 Question 段 → 返回 null（由调用方静默丢弃，AD-5）。
 */
export function parseDnsQuery(packet: Uint8Array): DnsQuery | null {
  const n: number = packet.length;
  if (n < 28) {
    return null;
  }
  const ipVer: number = (packet[0] >> 4) & 0x0F;
  let udpOff: number = -1;
  let ipLen: number = 0;

  if (ipVer === 4) {
    const ihl: number = (packet[0] & 0x0F) * 4;
    if (ihl < 20 || n < ihl + 20) {
      return null;
    }
    if (packet[9] !== PROTO_UDP) {
      return null;
    }
    udpOff = ihl;
    ipLen = ihl;
  } else if (ipVer === 6) {
    if (n < 40 + 20) {
      return null;
    }
    udpOff = ipv6UdpOffset(packet, n);
    if (udpOff < 0) {
      return null;
    }
    ipLen = 40;
  } else {
    return null;
  }

  const dstPort: number = (packet[udpOff + 2] << 8) | packet[udpOff + 3];
  if (dstPort !== DNS_PORT) {
    return null;
  }
  const udpLen: number = (packet[udpOff + 4] << 8) | packet[udpOff + 5];
  if (udpLen < 8 + 12) {
    return null;
  }
  const dnsOff: number = udpOff + 8;
  // UDP 长度可能小于包长（尾部 padding），以此界定 DNS 报文边界
  const udpEnd: number = Math.min(n, udpOff + udpLen);
  if (udpEnd < dnsOff + 12) {
    return null;
  }

  const transId: number = (packet[dnsOff] << 8) | packet[dnsOff + 1];
  const qdcount: number = (packet[dnsOff + 4] << 8) | packet[dnsOff + 5];
  if (qdcount < 1) {
    return null;
  }

  const nm: NameParse = readName(packet, dnsOff + 12, udpEnd);
  if (!nm.ok) {
    return null;
  }
  const qEnd: number = nm.end + 4;
  if (qEnd > udpEnd) {
    return null;
  }
  const qtype: number = (packet[nm.end] << 8) | packet[nm.end + 1];
  const qclass: number = (packet[nm.end + 2] << 8) | packet[nm.end + 3];

  const q: DnsQuery = {
    ipVersion: ipVer,
    transId: transId,
    qname: nm.name,
    qtype: qtype,
    qclass: qclass,
    dnsOffset: dnsOff,
    questionEnd: qEnd,
    udpOffset: udpOff,
    ipHeaderLen: ipLen
  };
  return q;
}

// ------------------------------------------------------------ DNS 应答构造

/**
 * 构造 DNS 应答体（不含 IP/UDP 头）。
 * Question 段按原字节整段拷贝（AD-2），只改 Header 与追加 Answer。
 */
function buildDnsBody(raw: Uint8Array, q: DnsQuery, rcode: number, answer: Uint8Array | null): Uint8Array {
  const qStart: number = q.dnsOffset + 12;
  const qLen: number = q.questionEnd - qStart;
  if (qLen < 0) {
    return new Uint8Array(0);
  }
  const ansLen: number = answer === null ? 0 : answer.length;
  const total: number = 12 + qLen + ansLen;
  const out: Uint8Array = new Uint8Array(total);

  // ID 原样
  out[0] = raw[q.dnsOffset];
  out[1] = raw[q.dnsOffset + 1];

  // Flags：保留原 opcode / RD / Z，置 QR + RA，重写 RCODE
  let flags: number = (raw[q.dnsOffset + 2] << 8) | raw[q.dnsOffset + 3];
  flags = (flags | FLAG_QR | FLAG_RA) & (0xFFFF ^ FLAG_RCODE_MASK);
  flags = flags | (rcode & FLAG_RCODE_MASK);
  out[2] = (flags >> 8) & 0xFF;
  out[3] = flags & 0xFF;

  // QDCOUNT = 1, ANCOUNT = answer ? 1 : 0, NS/AR = 0
  out[4] = 0;
  out[5] = 1;
  const ancount: number = answer === null ? 0 : 1;
  out[6] = (ancount >> 8) & 0xFF;
  out[7] = ancount & 0xFF;
  out[8] = 0;
  out[9] = 0;
  out[10] = 0;
  out[11] = 0;

  // Question 段原样拷贝
  for (let i = 0; i < qLen; i++) {
    out[12 + i] = raw[qStart + i];
  }
  // Answer
  if (answer !== null) {
    for (let i = 0; i < ansLen; i++) {
      out[12 + qLen + i] = answer[i];
    }
  }
  return out;
}

/** A 记录应答：域名指针指向 Question 的 QNAME（偏移 12），TTL 60s */
function buildAnswerA(ip: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(16);
  out[0] = 0xC0;   // name: pointer
  out[1] = 0x0C;   // → offset 12
  out[2] = 0x00;   // type A
  out[3] = 0x01;
  out[4] = 0x00;   // class IN
  out[5] = 0x01;
  out[6] = 0x00;   // TTL = 60
  out[7] = 0x00;
  out[8] = 0x00;
  out[9] = 0x3C;
  out[10] = 0x00;  // RDLENGTH = 4
  out[11] = 0x04;
  out[12] = ip[0];
  out[13] = ip[1];
  out[14] = ip[2];
  out[15] = ip[3];
  return out;
}

/** NXDOMAIN：域名不存在 */
export function buildNxDomain(raw: Uint8Array, q: DnsQuery): Uint8Array {
  return buildDnsBody(raw, q, RCODE_NXDOMAIN, null);
}

/** A 记录应答（通常传 [0,0,0,0] 制造「解析成功但连不上」） */
export function buildAddressResponse(raw: Uint8Array, q: DnsQuery, ipv4: number[]): Uint8Array {
  const ip: Uint8Array = new Uint8Array(4);
  for (let i = 0; i < 4 && i < ipv4.length; i++) {
    ip[i] = ipv4[i] & 0xFF;
  }
  return buildDnsBody(raw, q, RCODE_NOERROR, buildAnswerA(ip));
}

/** SERVFAIL：上游超时 / 在途任务超限时使用 */
export function buildServFail(raw: Uint8Array, q: DnsQuery): Uint8Array {
  return buildDnsBody(raw, q, RCODE_SERVFAIL, null);
}

// ---------------------------------------------------------- 校验和（纯函数）

/** 16 位一组累加，返回未折叠的和 */
function sum16(bytes: Uint8Array, start: number, len: number, init: number): number {
  let s: number = init;
  let i: number = 0;
  while (i + 1 < len) {
    s += (bytes[start + i] << 8) | bytes[start + i + 1];
    i += 2;
  }
  if (i < len) {
    s += bytes[start + i] << 8;   // 奇数字节补零
  }
  return s;
}

/** 折叠进 16 位并取反 */
function fold(sum: number): number {
  let s: number = sum;
  while ((s >> 16) !== 0) {
    s = (s & 0xFFFF) + (s >> 16);
  }
  return ((~s) & 0xFFFF);
}

function udpChecksumV4(pkt: Uint8Array, udpOff: number, udpLen: number): number {
  let s: number = 0;
  s = sum16(pkt, 12, 8, s);        // 源 + 目的 IP
  s += PROTO_UDP;                  // 协议号（占 16 位的高字节位）
  s += udpLen;                     // UDP 长度
  s = sum16(pkt, udpOff, udpLen, s);
  const c: number = fold(s);
  return c === 0 ? 0xFFFF : c;     // 校验和结果为 0 时按规范写 0xFFFF
}

function udpChecksumV6(pkt: Uint8Array, udpOff: number, udpLen: number): number {
  let s: number = 0;
  s = sum16(pkt, 8, 32, s);        // 源 + 目的 IPv6 地址
  s += udpLen;                     // 32 位长度的低 16 位
  s += PROTO_UDP;
  s = sum16(pkt, udpOff, udpLen, s);
  const c: number = fold(s);
  return c === 0 ? 0xFFFF : c;
}

// --------------------------------------------------- 封装回 IP/UDP（可直接写回 TUN）

/**
 * 把 DNS 应答体封装成完整 IP 包：交换源/目的地址与端口，重算校验和。
 * IPv4 保留原 IP 头（含 options）；IPv6 重新构造 40 字节头，不带扩展头。
 */
export function buildResponsePacket(raw: Uint8Array, q: DnsQuery, dnsPayload: Uint8Array): Uint8Array {
  const dnsLen: number = dnsPayload.length;
  const udpLen: number = 8 + dnsLen;
  const srcPort: number = (raw[q.udpOffset] << 8) | raw[q.udpOffset + 1];
  const dstPort: number = (raw[q.udpOffset + 2] << 8) | raw[q.udpOffset + 3];

  if (q.ipVersion === 4) {
    const ihl: number = q.ipHeaderLen;
    const total: number = ihl + udpLen;
    const out: Uint8Array = new Uint8Array(total);

    for (let i = 0; i < ihl; i++) {
      out[i] = raw[i];
    }
    // 交换源/目的 IP
    for (let i = 0; i < 4; i++) {
      out[12 + i] = raw[16 + i];
      out[16 + i] = raw[12 + i];
    }
    out[2] = (total >> 8) & 0xFF;   // total length
    out[3] = total & 0xFF;
    out[6] = 0;                      // flags/frag 清零
    out[7] = 0;
    out[8] = 64;                     // TTL
    out[9] = PROTO_UDP;
    out[10] = 0;                     // checksum 先置 0
    out[11] = 0;
    const cs: number = fold(sum16(out, 0, ihl, 0));
    out[10] = (cs >> 8) & 0xFF;
    out[11] = cs & 0xFF;

    // UDP 头：源端口 = 原目的端口(53)，目的端口 = 原源端口
    out[ihl] = (dstPort >> 8) & 0xFF;
    out[ihl + 1] = dstPort & 0xFF;
    out[ihl + 2] = (srcPort >> 8) & 0xFF;
    out[ihl + 3] = srcPort & 0xFF;
    out[ihl + 4] = (udpLen >> 8) & 0xFF;
    out[ihl + 5] = udpLen & 0xFF;
    out[ihl + 6] = 0;
    out[ihl + 7] = 0;
    for (let i = 0; i < dnsLen; i++) {
      out[ihl + 8 + i] = dnsPayload[i];
    }
    const uc: number = udpChecksumV4(out, ihl, udpLen);
    out[ihl + 6] = (uc >> 8) & 0xFF;
    out[ihl + 7] = uc & 0xFF;
    return out;
  }

  // IPv6：重新构造固定 40 字节头，不带扩展头（简化回写路径）
  const total6: number = 40 + udpLen;
  const out6: Uint8Array = new Uint8Array(total6);
  out6[0] = 0x60;                    // version 6
  out6[1] = 0;
  out6[2] = 0;
  out6[3] = 0;
  out6[4] = (udpLen >> 8) & 0xFF;    // payload length
  out6[5] = udpLen & 0xFF;
  out6[6] = PROTO_UDP;               // next header
  out6[7] = 64;                      // hop limit
  // 交换 128 位地址：请求 src 在 8..23，dst 在 24..39
  for (let i = 0; i < 16; i++) {
    out6[8 + i] = raw[24 + i];
    out6[24 + i] = raw[8 + i];
  }
  out6[40] = (dstPort >> 8) & 0xFF;
  out6[41] = dstPort & 0xFF;
  out6[42] = (srcPort >> 8) & 0xFF;
  out6[43] = srcPort & 0xFF;
  out6[44] = (udpLen >> 8) & 0xFF;
  out6[45] = udpLen & 0xFF;
  out6[46] = 0;
  out6[47] = 0;
  for (let i = 0; i < dnsLen; i++) {
    out6[40 + 8 + i] = dnsPayload[i];
  }
  const uc6: number = udpChecksumV6(out6, 40, udpLen);
  out6[46] = (uc6 >> 8) & 0xFF;
  out6[47] = uc6 & 0xFF;
  return out6;
}
