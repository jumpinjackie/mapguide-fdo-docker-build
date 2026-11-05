using System.Net;
using MapGuide.MapAgent.Client;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

/// <summary>
/// Rendering service tests. These are the operations that stream binary images, so they are the
/// ones that prove the OpenAPI image response definitions (image/png, image/gif, image/jpeg,
/// image/tiff) are correct: the generated client must hand back a <see cref="Stream"/>, and the
/// bytes must carry the right image signature.
/// </summary>
[Collection(MapAgentCollection.Name)]
public sealed class RenderingTests
{
    private readonly MapAgentFixture _fx;

    public RenderingTests(MapAgentFixture fx) => _fx = fx;

    // A viewport over the Sheboygan sample data, matching test/rendering_service_api.http.
    private static void ApplySampleView(
        MapGuide.MapAgent.Client.GetMapImage.GetMapImageRequestBuilder.GetMapImageRequestBuilderGetQueryParameters q,
        string format)
    {
        q.OPERATION = "GETMAPIMAGE";
        q.VERSION = "3.0.0"; // GetMapImage supports 1.0.0 and 3.0.0
        q.MAPDEFINITION = MapAgentFixture.SampleMapDefinition;
        q.FORMAT = format;
        q.SETVIEWCENTERX = -87.73025425093128;
        q.SETVIEWCENTERY = 43.744459064634064;
        q.SETVIEWSCALE = 100000;
        q.SETDISPLAYWIDTH = 585;
        q.SETDISPLAYHEIGHT = 893;
        q.SETDISPLAYDPI = 96;
    }

    [Theory]
    [InlineData("PNG", "image/png")]
    [InlineData("GIF", "image/gif")]
    [InlineData("JPG", "image/jpeg")]
    public async Task GetMapImage_streams_a_valid_image(string format, string expectedMediaType)
    {
        // Via the generated client: the return value must be a non-empty image stream.
        var stream = await _fx.Client.GetMapImage.GetAsync(
            c => ApplySampleView(c.QueryParameters, format));
        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
        StreamAssert.AssertIsImageFormat(format, bytes);

        // Via raw HTTP: the response Content-Type must match the format, proving the spec's
        // declared media types agree with what the server actually sends.
        var (status, contentType, rawBytes) = await _fx.GetRawAsync("GETMAPIMAGE",
            new Dictionary<string, string>
            {
                ["VERSION"] = "3.0.0",
                ["MAPDEFINITION"] = MapAgentFixture.SampleMapDefinition,
                ["FORMAT"] = format,
                ["SETVIEWCENTERX"] = "-87.73025425093128",
                ["SETVIEWCENTERY"] = "43.744459064634064",
                ["SETVIEWSCALE"] = "100000",
                ["SETDISPLAYWIDTH"] = "585",
                ["SETDISPLAYHEIGHT"] = "893",
                ["SETDISPLAYDPI"] = "96",
            });

        Assert.Equal(HttpStatusCode.OK, status);
        Assert.Equal(expectedMediaType, contentType);
        StreamAssert.AssertIsImageFormat(format, rawBytes);
    }

    [Fact]
    public async Task GetLegendImage_streams_a_valid_png()
    {
        var stream = await _fx.Client.GetLegendImage.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETLEGENDIMAGE";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.LAYERDEFINITION = MapAgentFixture.SampleLayerDefinition;
            c.QueryParameters.SCALE = 100000;
            c.QueryParameters.WIDTH = 300;
            c.QueryParameters.HEIGHT = 100;
            c.QueryParameters.FORMAT = "PNG";
        });

        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
        StreamAssert.AssertIsImageFormat("PNG", bytes);
    }
}
