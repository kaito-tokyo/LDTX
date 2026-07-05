// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

const apiBase = 'https://api.appstoreconnect.apple.com';

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function privateKeyBytes(pem) {
  const base64 = pem
    .replace(/\\n/g, '\n')
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');

  return Buffer.from(base64, 'base64');
}

export class AppStoreConnectAPI {
  constructor(issuer, keyId, key) {
    this.issuer = issuer;
    this.keyId = keyId;
    this.key = key;
  }

  async products() {
    return this.getAll('/v1/ciProducts?limit=200');
  }

  async productWorkflows(productId) {
    return this.getAll(`/v1/ciProducts/${encodeURIComponent(productId)}/workflows?limit=200`);
  }

  async workflowBuildRuns(workflowId) {
    return this.getAll(`/v1/ciWorkflows/${encodeURIComponent(workflowId)}/buildRuns?limit=200`);
  }

  async buildActions(buildId) {
    return this.getAll(`/v1/ciBuildRuns/${encodeURIComponent(buildId)}/actions?limit=200`);
  }

  async actionArtifacts(actionId) {
    return this.getAll(`/v1/ciBuildActions/${encodeURIComponent(actionId)}/artifacts?limit=200`);
  }

  async relatedResource(resource, relationshipName) {
    const related = resource.relationships?.[relationshipName]?.links?.related;
    if (!related) {
      return undefined;
    }

    const relatedUrl = new URL(related, apiBase);
    const response = await this.get(relatedUrl.pathname + relatedUrl.search);
    return response.data;
  }

  async jwt() {
    const issuedAt = Math.floor(Date.now() / 1000) - 60;
    const header = {
      alg: 'ES256',
      kid: this.keyId,
      typ: 'JWT',
    };
    const payload = {
      iss: this.issuer,
      iat: issuedAt,
      exp: issuedAt + 19 * 60,
      aud: 'appstoreconnect-v1',
    };
    const signingInput = [base64url(JSON.stringify(header)), base64url(JSON.stringify(payload))].join('.');
    const subtle = globalThis.crypto?.subtle;
    if (!subtle) {
      throw new Error('WebCrypto subtle API is unavailable in this Node runtime.');
    }

    const privateKey = await subtle.importKey(
      'pkcs8',
      privateKeyBytes(this.key),
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign'],
    );
    const signature = await subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      privateKey,
      new TextEncoder().encode(signingInput),
    );

    return `${signingInput}.${Buffer.from(signature).toString('base64url')}`;
  }

  async getAll(pathname) {
    const items = [];
    let next = pathname;

    while (next) {
      const response = await this.get(next);
      items.push(...(response.data ?? []));
      if (response.links?.next) {
        const nextUrl = new URL(response.links.next);
        next = nextUrl.pathname + nextUrl.search;
      } else {
        next = undefined;
      }
    }

    return items;
  }

  async get(pathname) {
    const response = await fetch(`${apiBase}${pathname}`, {
      headers: {
        Authorization: `Bearer ${await this.jwt()}`,
      },
    });
    if (!response.ok) {
      throw new Error(`GET ${pathname} failed with ${response.status}: ${await response.text()}`);
    }

    return response.json();
  }
}
