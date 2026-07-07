// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

const apiBase = 'https://api.appstoreconnect.apple.com';

/**
 * Encodes a string using the base64url alphabet used by JWT segments.
 *
 * @param {string} value
 * @returns {string}
 */
function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

/**
 * Converts a PKCS#8 PEM string into DER bytes for WebCrypto import.
 *
 * @param {string} pem
 * @returns {Buffer}
 */
function privateKeyBytes(pem) {
  const base64 = pem
    .replace(/\\n/g, '\n')
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');

  return Buffer.from(base64, 'base64');
}

/**
 * Decodes a base64-encoded PEM string from environment-variable storage.
 *
 * @param {string} base64
 * @returns {string}
 */
export function pemFromBase64(base64) {
  return Buffer.from(base64, 'base64').toString('utf8');
}

/**
 * Minimal App Store Connect API client used by release automation.
 *
 * This class intentionally stays low-level: it handles authentication,
 * pagination, and simple relationship traversal, while release-specific build
 * matching lives in `notarized-build.mjs`.
 */
export class AppStoreConnectAPI {
  /**
   * @param {string} issuer App Store Connect API issuer ID.
   * @param {string} keyId App Store Connect API key ID.
   * @param {string} key PKCS#8 private key PEM contents.
   */
  constructor(issuer, keyId, key) {
    this.issuer = issuer;
    this.keyId = keyId;
    this.key = key;
  }

  /**
   * Lists Xcode Cloud products visible to the current key.
   *
   * @returns {Promise<any[]>}
   */
  async products() {
    return this.getAll('/v1/ciProducts?limit=200');
  }

  /**
   * Lists workflows for a given Xcode Cloud product.
   *
   * @param {string} productId
   * @returns {Promise<any[]>}
   */
  async productWorkflows(productId) {
    return this.getAll(`/v1/ciProducts/${encodeURIComponent(productId)}/workflows?limit=200`);
  }

  /**
   * Lists build runs for a workflow by eagerly following pagination.
   *
   * @param {string} workflowId
   * @returns {Promise<any[]>}
   */
  async workflowBuildRuns(workflowId) {
    return this.getAll(`/v1/ciWorkflows/${encodeURIComponent(workflowId)}/buildRuns?limit=200`);
  }

  /**
   * Yields build-run pages for callers that want to control matching strategy
   * without loading the full history up front.
   *
   * @param {string} workflowId
   * @param {{ sort?: string }} [options]
   * @returns {AsyncGenerator<any[], void, void>}
   */
  async *workflowBuildRunPages(workflowId, { sort } = {}) {
    const query = new URLSearchParams({ limit: '50' });
    if (sort) {
      query.set('sort', sort);
    }

    let next = `/v1/ciWorkflows/${encodeURIComponent(workflowId)}/buildRuns?${query}`;
    while (next) {
      const response = await this.get(next);
      yield response.data ?? [];
      if (response.links?.next) {
        const nextUrl = new URL(response.links.next);
        next = nextUrl.pathname + nextUrl.search;
      } else {
        next = undefined;
      }
    }
  }

  /**
   * Lists actions belonging to a build run.
   *
   * @param {string} buildId
   * @returns {Promise<any[]>}
   */
  async buildActions(buildId) {
    return this.getAll(`/v1/ciBuildRuns/${encodeURIComponent(buildId)}/actions?limit=200`);
  }

  /**
   * Lists artifacts emitted by a build action.
   *
   * @param {string} actionId
   * @returns {Promise<any[]>}
   */
  async actionArtifacts(actionId) {
    return this.getAll(`/v1/ciBuildActions/${encodeURIComponent(actionId)}/artifacts?limit=200`);
  }

  /**
   * Follows a JSON:API related-resource link for the named relationship.
   *
   * @param {any} resource
   * @param {string} relationshipName
   * @returns {Promise<any|undefined>}
   */
  async relatedResource(resource, relationshipName) {
    const related = resource.relationships?.[relationshipName]?.links?.related;
    if (!related) {
      return undefined;
    }

    const relatedUrl = new URL(related, apiBase);
    const response = await this.get(relatedUrl.pathname + relatedUrl.search);
    return response.data;
  }

  /**
   * Builds a short-lived JWT for the App Store Connect API.
   *
   * @returns {Promise<string>}
   */
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

  /**
   * Follows JSON:API pagination and flattens the returned `data` arrays.
   *
   * @param {string} pathname
   * @returns {Promise<any[]>}
   */
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

  /**
   * Performs an authenticated GET request against the App Store Connect API.
   *
   * @param {string} pathname
   * @returns {Promise<any>}
   */
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
