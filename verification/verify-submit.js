#!/usr/bin/env node
/**
 * verify-submit.js
 * Automated source code verification submitter for AetherZone contracts on Shidoscan
 * Supports --dry-run mode for previewing payloads and validation.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const querystring = require('querystring');

const IS_DRY_RUN = process.argv.includes('--dry-run');
const EXPLORER_API = 'https://shidoscan.net/api';

// Contract deployment definitions
const CONTRACTS = [
  {
    name: 'StakePoolFactory',
    contractName: 'AetherStakeFactory.v6.sol:StakePoolFactory',
    address: '0x04EA2C2A1aD9D6654bF145D8513255F25904549b',
    standardJsonFile: 'verify-StakePoolFactory.standard.json',
    compilerVersion: 'v0.8.26+commit.8a97fa7a',
    runs: '200',
    evmVersion: 'paris',
    constructorArgs: '000000000000000000000000480cf2fa782b6ed100db723b37861af78cbc0298'
  },
  {
    name: 'AetherStakePool',
    contractName: 'AetherStakeFactory.v6.sol:AetherStakePool',
    address: '0x480cF2FA782b6ED100db723B37861aF78Cbc0298',
    standardJsonFile: 'verify-AetherStakePool.standard.json',
    compilerVersion: 'v0.8.26+commit.8a97fa7a',
    runs: '200',
    evmVersion: 'paris',
    constructorArgs: ''
  },
  {
    name: 'AetherLPGauge',
    contractName: 'AetherLPGauge.sol:AetherLPGauge',
    address: '0xECbd5f2dfe7033f2c62E2FfB668b600d96946E20',
    standardJsonFile: 'verify-AetherLPGauge.standard.json',
    compilerVersion: 'v0.8.26+commit.8a97fa7a',
    runs: '200',
    evmVersion: 'paris',
    constructorArgs: ''
  },
  {
    name: 'AetherReserveEscrow (Active)',
    contractName: 'AetherReserveEscrow.sol:AetherReserveEscrow',
    address: '0xe6F851dBC99Dfad6d70c797AEf19BCDd22301b28',
    standardJsonFile: 'verify-AetherReserveEscrow.standard.json',
    compilerVersion: 'v0.8.26+commit.8a97fa7a',
    runs: '200',
    evmVersion: 'paris',
    constructorArgs: ''
  },
  {
    name: 'AetherReserveEscrow (V1)',
    contractName: 'AetherReserveEscrow.sol:AetherReserveEscrow',
    address: '0x86526cA80fC494279251a12018413bf5F85C07eC',
    standardJsonFile: 'verify-AetherReserveEscrow.standard.json',
    compilerVersion: 'v0.8.26+commit.8a97fa7a',
    runs: '200',
    evmVersion: 'paris',
    constructorArgs: ''
  }
];

function findJsonFile(filename) {
  const possiblePaths = [
    path.join(__dirname, filename),
    path.join(__dirname, '..', filename),
    path.join('/var/www/AetherzoneMaster', filename),
    path.join('/var/www/AetherzoneMaster/staking-deploy', filename),
    path.resolve(process.cwd(), filename)
  ];
  for (const p of possiblePaths) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function submitVerification(payload) {
  return new Promise((resolve, reject) => {
    const postData = querystring.stringify(payload);
    const req = https.request(EXPLORER_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(postData)
      },
      timeout: 30000
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(body);
          resolve({ statusCode: res.statusCode, data: json });
        } catch (e) {
          resolve({ statusCode: res.statusCode, raw: body });
        }
      });
    });

    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timed out'));
    });
    req.write(postData);
    req.end();
  });
}

function checkVerifyStatus(guid) {
  return new Promise((resolve) => {
    const url = `${EXPLORER_API}?module=contract&action=checkverifystatus&guid=${encodeURIComponent(guid)}`;
    https.get(url, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          resolve({ raw: body });
        }
      });
    }).on('error', (err) => resolve({ error: err.message }));
  });
}

async function main() {
  console.log('======================================================================');
  console.log('       AetherZone Smart Contract Verification Submitter               ');
  console.log('       Target Explorer: Shidoscan (Blockscout API)                    ');
  console.log(`       Mode: ${IS_DRY_RUN ? 'DRY-RUN (Simulate only)' : 'LIVE SUBMISSION'}`);
  console.log('======================================================================\n');

  for (const c of CONTRACTS) {
    console.log(`----------------------------------------------------------------------`);
    console.log(`[+] Processing: ${c.name} (${c.address})`);
    console.log(`    Contract Identifier: ${c.contractName}`);
    console.log(`    Compiler Version:    ${c.compilerVersion}`);
    console.log(`    EVM Target:          ${c.evmVersion} (Optimizer: 200 runs)`);
    console.log(`    Constructor Args:    ${c.constructorArgs || '(None)'}`);

    const filePath = findJsonFile(c.standardJsonFile);
    if (!filePath) {
      console.error(`[-] ERROR: Standard JSON file not found for ${c.name}: ${c.standardJsonFile}`);
      continue;
    }

    console.log(`    Standard JSON File:  ${filePath}`);
    const jsonContent = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(jsonContent);
    const sourceCount = Object.keys(parsed.sources || {}).length;
    console.log(`    Included Sources:    ${sourceCount} files (${(jsonContent.length / 1024).toFixed(1)} KB)`);

    const payload = {
      module: 'contract',
      action: 'verifysourcecode',
      contractaddress: c.address,
      sourceCode: jsonContent,
      codeformat: 'solidity-standard-json-input',
      contractname: c.contractName,
      compilerversion: c.compilerVersion,
      optimizationUsed: '1',
      runs: c.runs,
      evmversion: c.evmVersion,
      constructorArguements: c.constructorArgs
    };

    if (IS_DRY_RUN) {
      console.log(`    [DRY-RUN] Verification payload validated. Ready to POST to ${EXPLORER_API}.`);
      console.log(`    [DRY-RUN] Direct Web URL: https://shidoscan.net/address/${c.address}#code`);
      console.log(`    [âœ“] DRY-RUN SUCCESS: Payload well-formed.`);
    } else {
      console.log(`    [*] Submitting verification to Shidoscan API...`);
      try {
        const resp = await submitVerification(payload);
        console.log(`    Status Code: ${resp.statusCode}`);
        console.log(`    Response:   `, JSON.stringify(resp.data || resp.raw));

        const resultGuid = resp.data && (resp.data.result || resp.data.message);
        if (resp.data && resp.data.status === '1' && resp.data.result) {
          console.log(`    [i] Submission GUID: ${resp.data.result}. Polling verification status in 4s...`);
          await new Promise(r => setTimeout(r, 4000));
          const statusResp = await checkVerifyStatus(resp.data.result);
          console.log(`    [i] Verification Result:`, JSON.stringify(statusResp));
        } else if (resp.data && resp.data.result && typeof resp.data.result === 'string' && resp.data.result.toLowerCase().includes('already verified')) {
          console.log(`    [âœ“] Contract is already verified on Shidoscan!`);
        }
      } catch (err) {
        console.error(`    [-] Verification request failed:`, err.message);
      }
    }
    console.log('');
  }

  console.log('======================================================================');
  console.log(`Verification workflow complete.`);
  if (IS_DRY_RUN) {
    console.log(`Run 'node verify-submit.js' (without --dry-run) to submit live verifications.`);
  } else {
    console.log(`Check contract pages on Shidoscan to confirm verification badges.`);
  }
  console.log('======================================================================');
}

main().catch(console.error);
