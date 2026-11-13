/**
 * DnsCodec 单元测试（本机 node 直跑，不装机）
 *
 * 运行：bash test/run.sh
 * 前置：run.sh 会把 core/DnsCodec.ets 复制成 .test-build/DnsCodec.ts
 *
 * 覆盖 ADR-001 的 AD-2（Question 段原字节拷贝）与 AD-5（错误语义）。
 */

import assert from 'node:assert';
import {
  parseDnsQuery,
  buildNxDomain,
  buildAddressResponse,
  buildServFail,
  buildResponsePacket,
  RCODE_NOERROR,
  RCODE_SERVFAIL,
  RCODE_NXDOMAIN,
  QTYPE_A,
  QTYPE_AAAA
} from '../.test-build/DnsCodec.ts';
// 纯类型必须用 import type：node 的 type stripping 只擦除类型，不会把它当值解析
import type { DnsQuery } from '../.test-build/DnsCodec.ts';

let pass = 0;
let fail = 0;

function ok(cond: boolean, name: string): void {
  if (cond) {
    pass++;
  } else {
    fail++;
    console.error(`  ✗ ${name}`);
  }
}

function eq(actual: unknown, expected: unknown, name: string): void {
  if (actual === expected) {
    pass++;
  } else {
    fail++;
    console.error(`  ✗ ${name}（期望 ${String(expected)}，实际 ${String(actual)}）`);
  }
}

// ------------------------------------------------------------ 构造测试数据

function writeU16(buf: Uint8Array, off: number, v: number): void {
  buf[off] = (v >> 8) & 0xFF;
  buf[off + 1] = v & 0xFF;
}

function encodeQname(name: string): number[] {
  const out: number[] = [];
  if (name.length > 0) {
    const parts: string[] = name.split('.');
    for (const p of parts) {
      out.push(p.length);
      for (let i = 0; i < p.length; i++) {
        out.push(p.charCodeAt(i));
      }
    }
  }
  out.push(0);
  return out;
}

/** 构造 DNS 报文：header + question */
function buildDnsMessage(transId: number, name: string, qtype: number, rd: boolean): number[] {
  const msg: number[] = [];
  msg.push((transId >> 8) & 0xFF, transId & 0xFF);
  msg.push(rd ? 0x01 : 0x00, 0x00);   // flags: RD
  msg.push(0x00, 0x01);               // QDCOUNT
  msg.push(0x00, 0x00);               // ANCOUNT
  msg.push(0x00, 0x00);               // NSCOUNT
  msg.push(0x00, 0x00);               // ARCOUNT
  const q: number[] = encodeQname(name);
  for (const b of q) {
    msg.push(b);
  }
  msg.push((qtype >> 8) & 0xFF, qtype & 0xFF);   // QTYPE
  msg.push(0x00, 0x01);                           // QCLASS = IN
  return msg;
}

function cksum16(bytes: Uint8Array, start: number, len: number): number {
  let s = 0;
  let i = 0;
  while (i + 1 < len) {
    s += (bytes[start + i] << 8) | bytes[start + i + 1];
    i += 2;
  }
  if (i < len) {
    s += bytes[start + i] << 8;
  }
  while ((s >> 16) !== 0) {
    s = (s & 0xFFFF) + (s >> 16);
  }
  return s & 0xFFFF;
}

/** 构造完整 IPv4 UDP DNS 查询包 */
function buildIpv4Query(name: string, qtype: number, transId: number, dstPort: number): Uint8Array {
  const dns = buildDnsMessage(transId, name, qtype, true);
  const udpLen = 8 + dns.length;
  const total = 20 + udpLen;
  const out = new Uint8Array(total);

  out[0] = 0x45;                      // version 4, IHL 5
  out[1] = 0x00;
  writeU16(out, 2, total);
  writeU16(out, 4, 0x1234);           // id
  writeU16(out, 6, 0x0000);           // flags
  out[8] = 64;                        // ttl
  out[9] = 17;                        // udp
  // src = 10.0.0.2, dst = 10.0.0.1
  out[12] = 10; out[13] = 0; out[14] = 0; out[15] = 2;
  out[16] = 10; out[17] = 0; out[18] = 0; out[19] = 1;
  const ipcs = (~cksum16(out, 0, 20)) & 0xFFFF;
  writeU16(out, 10, ipcs);

  writeU16(out, 20, 54321);           // src port
  writeU16(out, 22, dstPort);         // dst port
  writeU16(out, 24, udpLen);
  writeU16(out, 26, 0);               // checksum 0（IPv4 允许）

  for (let i = 0; i < dns.length; i++) {
    out[28 + i] = dns[i];
  }
  return out;
}

/** 构造完整 IPv6 UDP DNS 查询包；withHopByHop 时插入 8 字节 Hop-by-Hop 头 */
function buildIpv6Query(name: string, qtype: number, transId: number, withHopByHop: boolean): Uint8Array {
  const dns = buildDnsMessage(transId, name, qtype, true);
  const extLen = withHopByHop ? 8 : 0;
  const udpLen = 8 + dns.length;
  const payload = extLen + udpLen;
  const total = 40 + payload;
  const out = new Uint8Array(total);

  out[0] = 0x60;
  writeU16(out, 4, payload);          // payload length
  out[6] = withHopByHop ? 0 : 17;     // next header: 0 = Hop-by-Hop, 17 = UDP
  out[7] = 64;
  // src = fd00::2, dst = fd00::1
  out[8 + 15] = 0x02;
  out[24 + 15] = 0x01;
  for (let i = 0; i < 10; i++) {
    out[8 + i] = 0xFD;
    out[24 + i] = 0xFD;
  }

  let udpOff = 40;
  if (withHopByHop) {
    out[40] = 17;                     // next header in ext = UDP
    out[41] = 0;                      // hdr ext len = (0+1)*8 = 8 bytes
    for (let i = 2; i < 8; i++) {
      out[40 + i] = 0;
    }
    udpOff = 48;
  }

  writeU16(out, udpOff, 54321);
  writeU16(out, udpOff + 2, 53);
  writeU16(out, udpOff + 4, udpLen);
  writeU16(out, udpOff + 6, 0);
  for (let i = 0; i < dns.length; i++) {
    out[udpOff + 8 + i] = dns[i];
  }
  return out;
}

function getFlags(dnsBody: Uint8Array): number {
  return (dnsBody[2] << 8) | dnsBody[3];
}

// ------------------------------------------------------------------- 用例

console.log('\n=== 1. IPv4 A 查询解析 ===');
{
  const pkt = buildIpv4Query('ads.pangolin-sdk-toutiao.com', QTYPE_A, 0xBEEF, 53);
  const q = parseDnsQuery(pkt);
  ok(q !== null, '解析成功');
  if (q !== null) {
    eq(q.ipVersion, 4, 'ipVersion');
    eq(q.transId, 0xBEEF, 'transId');
    eq(q.qname, 'ads.pangolin-sdk-toutiao.com', 'qname');
    eq(q.qtype, QTYPE_A, 'qtype');
    eq(q.qclass, 1, 'qclass');
    eq(q.ipHeaderLen, 20, 'ipHeaderLen');
    eq(q.udpOffset, 20, 'udpOffset');
    eq(q.dnsOffset, 28, 'dnsOffset');
    eq(q.questionEnd - q.dnsOffset, 12 + 30 + 4, 'question 段长度（12 头 + 30 名字 + 4 类型/类）');
  }
}

console.log('=== 2. 域名大小写：qname 归一化，Question 段保留原字节（AD-2）===');
{
  const mixed = 'Ads.Pangolin-SDK-TouTiao.COM';
  const pkt = buildIpv4Query(mixed, QTYPE_A, 1, 53);
  const q = parseDnsQuery(pkt);
  ok(q !== null, '解析成功');
  if (q !== null) {
    eq(q.qname, mixed.toLowerCase(), 'qname 已转小写');
    const nx = buildNxDomain(pkt, q);
    // Question 段应从 DNS 报文偏移 12 起原样拷贝
    const qSecRaw = pkt.slice(q.dnsOffset + 12, q.questionEnd);
    const qSecOut = nx.slice(12, 12 + qSecRaw.length);
    let same = true;
    for (let i = 0; i < qSecRaw.length; i++) {
      if (qSecRaw[i] !== qSecOut[i]) {
        same = false;
      }
    }
    ok(same, 'Question 段逐字节一致（含原大小写）');
  }
}

console.log('=== 3. NXDOMAIN 应答 ===');
{
  const pkt = buildIpv4Query('a.pangolin-sdk-toutiao.com', QTYPE_A, 0x0102, 53);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildNxDomain(pkt, q);
  eq(resp[0] << 8 | resp[1], 0x0102, '事务 ID 保持');
  const f = getFlags(resp);
  ok((f & 0x8000) !== 0, 'QR = 1');
  eq(f & 0x0F, RCODE_NXDOMAIN, 'RCODE = NXDOMAIN(3)');
  eq((resp[4] << 8) | resp[5], 1, 'QDCOUNT = 1');
  eq((resp[6] << 8) | resp[7], 0, 'ANCOUNT = 0');
}

console.log('=== 4. A 记录 0.0.0.0 应答 ===');
{
  const pkt = buildIpv4Query('b.pangolin-sdk-toutiao.com', QTYPE_A, 0x0203, 53);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildAddressResponse(pkt, q, [0, 0, 0, 0]);
  const f = getFlags(resp);
  eq(f & 0x0F, RCODE_NOERROR, 'RCODE = NOERROR');
  eq((resp[6] << 8) | resp[7], 1, 'ANCOUNT = 1');
  const qLen = q.questionEnd - (q.dnsOffset + 12);
  const ansOff = 12 + qLen;
  eq(resp[ansOff], 0xC0, 'Answer name 指针高字节');
  eq(resp[ansOff + 1], 0x0C, 'Answer name 指针低字节 → offset 12');
  eq((resp[ansOff + 2] << 8) | resp[ansOff + 3], 1, 'TYPE = A');
  eq((resp[ansOff + 10] << 8) | resp[ansOff + 11], 4, 'RDLENGTH = 4');
  eq(resp[ansOff + 12], 0, 'RDATA 0');
  eq(resp[ansOff + 15], 0, 'RDATA 末字节 0');
  eq(resp.length, 12 + qLen + 16, '总长度 = 头 + question + 16');
}

console.log('=== 5. SERVFAIL 应答 ===');
{
  const pkt = buildIpv4Query('c.example.com', QTYPE_A, 0x0304, 53);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildServFail(pkt, q);
  eq(getFlags(resp) & 0x0F, RCODE_SERVFAIL, 'RCODE = SERVFAIL(2)');
}

console.log('=== 6. IPv4 回写包：地址/端口交换 + 校验和自校验 ===');
{
  const pkt = buildIpv4Query('d.pangolin-sdk-toutiao.com', QTYPE_A, 0x0405, 53);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildNxDomain(pkt, q);
  const out = buildResponsePacket(pkt, q, resp);

  eq((out[0] >> 4) & 0x0F, 4, 'version = 4');
  eq((out[0] & 0x0F) * 4, 20, 'IHL = 5');
  eq((out[2] << 8) | out[3], out.length, 'total length 与包长一致');
  eq(out[9], 17, 'protocol = UDP');
  // 源/目的 IPv4 互换：原 src 10.0.0.2 dst 10.0.0.1
  eq(`${out[12]}.${out[13]}.${out[14]}.${out[15]}`, '10.0.0.1', '响应源 = 请求目的');
  eq(`${out[16]}.${out[17]}.${out[18]}.${out[19]}`, '10.0.0.2', '响应目的 = 请求源');
  // 端口互换：原 src 54321 dst 53
  eq((out[20] << 8) | out[21], 53, '响应源端口 = 53');
  eq((out[22] << 8) | out[23], 54321, '响应目的端口 = 原源端口');
  eq((out[24] << 8) | out[25], 8 + resp.length, 'UDP 长度正确');

  // 数学性质：IP 头（含 checksum）再求和取反应为 0
  const ipSum = cksum16(out, 0, 20);
  eq(ipSum, 0xFFFF, 'IPv4 头校验和自校验（含 checksum 求和 = 0xFFFF）');

  // UDP 校验和自校验：伪头 + UDP 段
  let s = 0;
  s += (out[12] << 8 | out[13]) + (out[14] << 8 | out[15]);
  s += (out[16] << 8 | out[17]) + (out[18] << 8 | out[19]);
  s += 17;
  s += 8 + resp.length;
  const udpLen = 8 + resp.length;
  const udpSum = cksum16(out, 20, udpLen);
  let total = s + udpSum;
  while ((total >> 16) !== 0) {
    total = (total & 0xFFFF) + (total >> 16);
  }
  eq(total & 0xFFFF, 0xFFFF, 'UDP 校验和自校验（伪头 + UDP 段 = 0xFFFF）');
}

console.log('=== 7. IPv6 查询解析（无扩展头）===');
{
  const pkt = buildIpv6Query('e.pangolin-sdk-toutiao.com', QTYPE_AAAA, 0x0506, false);
  const q = parseDnsQuery(pkt);
  ok(q !== null, '解析成功');
  if (q !== null) {
    eq(q.ipVersion, 6, 'ipVersion = 6');
    eq(q.qname, 'e.pangolin-sdk-toutiao.com', 'qname');
    eq(q.qtype, QTYPE_AAAA, 'qtype = AAAA');
    eq(q.udpOffset, 40, 'udpOffset = 40');
    eq(q.ipHeaderLen, 40, 'ipHeaderLen = 40');
  }
}

console.log('=== 8. IPv6 带 Hop-by-Hop 扩展头（V3 踩过的坑）===');
{
  const pkt = buildIpv6Query('f.pangolin-sdk-toutiao.com', QTYPE_A, 0x0607, true);
  const q = parseDnsQuery(pkt);
  ok(q !== null, '扩展头后仍能解析出 DNS');
  if (q !== null) {
    eq(q.udpOffset, 48, 'udpOffset 跳过 8 字节扩展头');
    eq(q.qname, 'f.pangolin-sdk-toutiao.com', 'qname');
  }
}

console.log('=== 9. IPv6 回写包：地址交换 + UDP 校验和（必算）===');
{
  const pkt = buildIpv6Query('g.pangolin-sdk-toutiao.com', QTYPE_A, 0x0708, false);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildNxDomain(pkt, q);
  const out = buildResponsePacket(pkt, q, resp);

  eq((out[0] >> 4) & 0x0F, 6, 'version = 6');
  eq(out[6], 17, 'next header = UDP（响应不带扩展头）');
  eq((out[4] << 8) | out[5], 8 + resp.length, 'payload length 正确');
  eq(out.length, 40 + 8 + resp.length, '包长 = 40 + UDP');
  eq((out[40] << 8) | out[41], 53, '响应源端口 = 53');
  eq((out[42] << 8) | out[43], 54321, '响应目的端口 = 原源端口');
  // 端口交换：请求 src fd00::2 → 响应 dst fd00::2（偏移 24+15 = 39）
  eq(out[23], 0x01, '响应源地址 = 请求目的地址（fd00::1 末字节在偏移 23）');
  eq(out[39], 0x02, '响应目的地址 = 请求源地址（fd00::2 末字节在偏移 39）');

  // UDP checksum 必填且自校验
  let s = 0;
  for (let i = 0; i < 16; i += 2) {
    s += (out[8 + i] << 8) | out[9 + i];
    s += (out[24 + i] << 8) | out[25 + i];
  }
  s += 8 + resp.length;
  s += 17;
  const udpSum = cksum16(out, 40, 8 + resp.length);
  let total = s + udpSum;
  while ((total >> 16) !== 0) {
    total = (total & 0xFFFF) + (total >> 16);
  }
  eq(total & 0xFFFF, 0xFFFF, 'IPv6 UDP 校验和自校验 = 0xFFFF');
}

console.log('=== 10. 错误语义（AD-5：一律返回 null，不抛异常）===');
{
  const pkt = buildIpv4Query('h.example.com', QTYPE_A, 1, 53);
  // 非 53 端口
  const other = buildIpv4Query('h.example.com', QTYPE_A, 1, 8080);
  eq(parseDnsQuery(other), null, '非 53 端口 → null');
  // 截断包
  eq(parseDnsQuery(pkt.slice(0, 10)), null, '截断包 → null');
  eq(parseDnsQuery(new Uint8Array(0)), null, '空包 → null');
  // 非 UDP（把协议号改成 TCP=6）
  const tcp = buildIpv4Query('h.example.com', QTYPE_A, 1, 53);
  tcp[9] = 6;
  eq(parseDnsQuery(tcp), null, '非 UDP → null');
  // QDCOUNT = 0
  const noQ = buildIpv4Query('h.example.com', QTYPE_A, 1, 53);
  noQ[28 + 4] = 0;
  noQ[28 + 5] = 0;
  eq(parseDnsQuery(noQ), null, 'QDCOUNT=0 → null');
  // 非法版本号
  const badVer = buildIpv4Query('h.example.com', QTYPE_A, 1, 53);
  badVer[0] = 0x75;
  eq(parseDnsQuery(badVer), null, 'IP version 7 → null');
}

console.log('=== 11. 事务 ID 与 flags 的 RD 位保留 ===');
{
  const pkt = buildIpv4Query('i.example.com', QTYPE_A, 0xABCD, 53);
  const q = parseDnsQuery(pkt) as DnsQuery;
  const resp = buildNxDomain(pkt, q);
  eq((resp[0] << 8) | resp[1], 0xABCD, '事务 ID 保持');
  ok(((getFlags(resp) & 0x0100) !== 0), 'RD 位保留（请求设了 RD）');
}

// ------------------------------------------------------------------ 汇总
console.log(`\n${'='.repeat(50)}`);
console.log(`通过 ${pass} 项，失败 ${fail} 项`);
if (fail > 0) {
  console.error('❌ 存在失败用例');
  process.exit(1);
}
console.log('✅ 全部通过');
