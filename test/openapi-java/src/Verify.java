package org.mapguide.mapagent;

import java.io.File;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

import org.mapguide.mapagent.api.RenderingApi;
import org.mapguide.mapagent.api.ResourceApi;
import org.mapguide.mapagent.api.SiteApi;

/**
 * Verifies the MapAgent OpenAPI spec through OpenAPI Generator's Java (okhttp-gson) client.
 *
 * Mirrors the C# and TypeScript harnesses: a plain XML document operation, a rendering operation
 * that must stream real image bytes, and the two error statuses the mapagent emits (401 and the
 * non-standard 559).
 *
 * Environment: MG_MAPAGENT_URL, MG_USER, MG_PASS.
 */
public final class Verify {

    private static final String MAP_DEFINITION =
        "Library://Samples/Sheboygan/Maps/Sheboygan.MapDefinition";

    private static final List<String> RESULTS = new ArrayList<>();
    private static int failures;

    private interface Check {
        void run() throws Exception;
    }

    private Verify() {
    }

    public static void main(String[] args) {
        String basePath = env("MG_MAPAGENT_URL", "http://localhost:8018/mapguide/mapagent/mapagent.fcgi");
        String user = env("MG_USER", "Administrator");
        String password = env("MG_PASS", "admin");

        ApiClient authenticated = new ApiClient();
        authenticated.setBasePath(basePath);
        authenticated.setUsername(user);
        authenticated.setPassword(password);

        ApiClient anonymous = new ApiClient();
        anonymous.setBasePath(basePath);

        SiteApi site = new SiteApi(authenticated);
        RenderingApi rendering = new RenderingApi(authenticated);
        ResourceApi resource = new ResourceApi(authenticated);

        check("GetSiteStatus returns a SiteStatus document", () -> {
            String xml = site.getSiteStatus("GETSITESTATUS", "4.0.0", null, null, null, null);
            if (xml == null || !xml.contains("SiteStatus")) {
                throw new IllegalStateException("unexpected body: " + xml);
            }
        });

        check("GetMapImage streams PNG bytes", () -> {
            File image = rendering.getMapImage(
                "GETMAPIMAGE", "3.0.0", null, null, null,
                MAP_DEFINITION, null, "PNG", null, null, null,
                new BigDecimal("-87.73025425093128"), new BigDecimal("43.744459064634064"),
                new BigDecimal("100000"), 96, 585, 893,
                null, null, null, null);

            byte[] bytes = Files.readAllBytes(image.toPath());
            assertMagic(bytes, new int[] { 0x89, 0x50, 0x4E, 0x47 }, "PNG");
        });

        check("anonymous GetSiteInfo is rejected with 401", () ->
            expectStatus(401, () ->
                new SiteApi(anonymous).getSiteInfo("GETSITEINFO", "4.0.0", null, null, null, null, null)));

        check("handler exception surfaces as 559", () ->
            expectStatus(559, () -> resource.enumerateResources(
                "ENUMERATERESOURCES", "4.0.0", "Library://Bogus/Bogus/",
                null, null, null, null, null, null, null, null, null)));

        for (String result : RESULTS) {
            System.out.println(result);
        }
        System.out.println();
        System.out.printf("%d/%d checks passed%n", RESULTS.size() - failures, RESULTS.size());
        if (failures > 0) {
            System.exit(1);
        }
    }

    private static void check(String name, Check body) {
        try {
            body.run();
            RESULTS.add("PASS  " + name);
        } catch (Throwable failure) {
            failures++;
            RESULTS.add("FAIL  " + name + ": " + failure);
        }
    }

    /** Asserts an operation failed with a specific HTTP status, and that nothing else did. */
    private static void expectStatus(int expected, Check body) throws Exception {
        try {
            body.run();
        } catch (ApiException error) {
            if (error.getCode() != expected) {
                throw new IllegalStateException("expected HTTP " + expected + ", got " + error.getCode());
            }
            return;
        }
        throw new IllegalStateException("expected HTTP " + expected + ", but the call succeeded");
    }

    private static void assertMagic(byte[] bytes, int[] magic, String label) {
        if (bytes.length < 100) {
            throw new IllegalStateException(label + ": body too small (" + bytes.length + " bytes)");
        }
        for (int i = 0; i < magic.length; i++) {
            if ((bytes[i] & 0xFF) != magic[i]) {
                throw new IllegalStateException(label + ": unexpected magic bytes");
            }
        }
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isEmpty() ? fallback : value;
    }
}
