/*
 * Verifies the MapAgent OpenAPI spec through OpenAPI Generator's typescript-fetch client.
 *
 * Mirrors the C# harness's coverage in the areas that prove the spec is faithful: a plain XML
 * document operation, a rendering operation that must stream real image bytes, and the two error
 * statuses the mapagent emits (401 and the non-standard 559).
 *
 * Environment: MG_MAPAGENT_URL, MG_USER, MG_PASS.
 */

import { Configuration, ResponseError } from './runtime';

// The generated client is browser-oriented and carries no node typings; this is the whole of the
// `process` surface the verifier touches.
declare const process: {
    env: Record<string, string | undefined>;
    exitCode?: number;
};
import {
    GetMapImageFORMATEnum,
    GetMapImageOPERATIONEnum,
    GetMapImageVERSIONEnum,
    RenderingApi,
} from './apis/RenderingApi';
import {
    EnumerateResourcesOPERATIONEnum,
    EnumerateResourcesVERSIONEnum,
    ResourceApi,
} from './apis/ResourceApi';
import {
    GetSiteInfoOPERATIONEnum,
    GetSiteInfoVERSIONEnum,
    GetSiteStatusOPERATIONEnum,
    GetSiteStatusVERSIONEnum,
    SiteApi,
} from './apis/SiteApi';

const basePath =
    process.env.MG_MAPAGENT_URL ?? 'http://localhost:8018/mapguide/mapagent/mapagent.fcgi';
const username = process.env.MG_USER ?? 'Administrator';
const password = process.env.MG_PASS ?? 'admin';

const authenticated = new Configuration({ basePath, username, password });
const anonymous = new Configuration({ basePath });

const MAP_DEFINITION = 'Library://Samples/Sheboygan/Maps/Sheboygan.MapDefinition';

interface IResult {
    name: string;
    ok: boolean;
    detail: string;
}

const results: IResult[] = [];

async function check(name: string, body: () => Promise<void>): Promise<void> {
    try {
        await body();
        results.push({ name, ok: true, detail: '' });
    } catch (error) {
        results.push({ name, ok: false, detail: error instanceof Error ? error.message : String(error) });
    }
}

/** Asserts an operation failed with a specific HTTP status, and that nothing else did. */
async function expectStatus(status: number, body: () => Promise<unknown>): Promise<void> {
    try {
        await body();
    } catch (error) {
        if (!(error instanceof ResponseError)) {
            throw new Error(`expected a ResponseError, got ${String(error)}`);
        }
        if (error.response.status !== status) {
            throw new Error(`expected HTTP ${status}, got ${error.response.status}`);
        }
        return;
    }
    throw new Error(`expected HTTP ${status}, but the call succeeded`);
}

function assertImageBytes(bytes: Uint8Array, magic: number[], label: string): void {
    if (bytes.length < 100) {
        throw new Error(`${label}: body too small (${bytes.length} bytes)`);
    }
    for (let i = 0; i < magic.length; i++) {
        if (bytes[i] !== magic[i]) {
            throw new Error(`${label}: unexpected magic bytes`);
        }
    }
}

async function main(): Promise<void> {
    const site = new SiteApi(authenticated);
    const rendering = new RenderingApi(authenticated);
    const resource = new ResourceApi(authenticated);

    await check('GetSiteStatus returns a SiteStatus document', async () => {
        const xml = await site.getSiteStatus({
            oPERATION: GetSiteStatusOPERATIONEnum.Getsitestatus,
            vERSION: GetSiteStatusVERSIONEnum._400,
        });
        if (!xml.includes('SiteStatus')) {
            throw new Error(`unexpected body: ${xml.slice(0, 200)}`);
        }
    });

    await check('GetMapImage streams PNG bytes', async () => {
        const response = await rendering.getMapImageRaw({
            oPERATION: GetMapImageOPERATIONEnum.Getmapimage,
            vERSION: GetMapImageVERSIONEnum._300,
            mAPDEFINITION: MAP_DEFINITION,
            fORMAT: GetMapImageFORMATEnum.Png,
            sETVIEWCENTERX: -87.73025425093128,
            sETVIEWCENTERY: 43.744459064634064,
            sETVIEWSCALE: 100000,
            sETDISPLAYDPI: 96,
            sETDISPLAYWIDTH: 585,
            sETDISPLAYHEIGHT: 893,
        });

        const contentType = response.raw.headers.get('content-type') ?? '';
        if (contentType !== 'image/png') {
            throw new Error(`expected image/png, got ${contentType}`);
        }
        assertImageBytes(new Uint8Array(await response.raw.arrayBuffer()), [0x89, 0x50, 0x4e, 0x47], 'PNG');
    });

    await check('anonymous GetSiteInfo is rejected with 401', () =>
        expectStatus(401, () =>
            new SiteApi(anonymous).getSiteInfo({
                oPERATION: GetSiteInfoOPERATIONEnum.Getsiteinfo,
                vERSION: GetSiteInfoVERSIONEnum._400,
            })));

    await check('handler exception surfaces as 559', () =>
        expectStatus(559, () =>
            resource.enumerateResources({
                oPERATION: EnumerateResourcesOPERATIONEnum.Enumerateresources,
                vERSION: EnumerateResourcesVERSIONEnum._400,
                rESOURCEID: 'Library://Bogus/Bogus/',
            })));

    for (const result of results) {
        console.log(`${result.ok ? 'PASS' : 'FAIL'}  ${result.name}${result.ok ? '' : `: ${result.detail}`}`);
    }

    const failed = results.filter((r) => !r.ok).length;
    console.log(`\n${results.length - failed}/${results.length} checks passed`);
    if (failed > 0) {
        process.exitCode = 1;
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
