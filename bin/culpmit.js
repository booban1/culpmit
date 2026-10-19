#!/usr/bin/env node
// Installs the latest Culpmit release into Applications and opens it

const { execFileSync } = require("child_process");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");

if (process.platform !== "darwin" || os.arch() !== "x64") {
  console.log("Culpmit is built for Intel Macs. Apple silicon support comes in a later version.");
  process.exit(1);
}

function get(url) {
  return new Promise((resolve, reject) => {
    const headers = { "User-Agent": "culpmit-installer", Accept: "application/vnd.github+json" };
    https.get(url, { headers }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(get(res.headers.location));
      }
      if (res.statusCode !== 200) return reject(new Error(`GitHub answered ${res.statusCode}`));
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve(Buffer.concat(chunks)));
    }).on("error", reject);
  });
}

(async () => {
  const release = JSON.parse(await get("https://api.github.com/repos/booban1/culpmit/releases/latest"));
  const asset = release.assets.find((a) => a.name.endsWith(".zip"));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "culpmit-"));
  const zip = path.join(dir, asset.name);
  console.log(`Downloading ${asset.name}`);
  fs.writeFileSync(zip, await get(asset.browser_download_url));
  execFileSync("/usr/bin/ditto", ["-x", "-k", zip, dir]);
  try {
    execFileSync("/usr/bin/pkill", ["-x", "Culpmit"]);
    execFileSync("/bin/sleep", ["1"]);
  } catch {}
  execFileSync("/usr/bin/ditto", [path.join(dir, "Culpmit.app"), "/Applications/Culpmit.app"]);
  execFileSync("/usr/bin/open", ["/Applications/Culpmit.app"]);
  console.log("Culpmit is in Applications and running in the menu bar.");
})().catch((error) => {
  console.error(`Culpmit's install stopped: ${error.message}`);
  process.exit(1);
});
