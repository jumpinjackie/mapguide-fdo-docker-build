using MapGuide.MapAgent.Client;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

[Collection(MapAgentCollection.Name)]
public sealed class CoordinateSystemGeoProcessingTests
{
    private readonly MapAgentFixture _fx;

    public CoordinateSystemGeoProcessingTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task CsConvertCoordinateSystemCodeToWkt_succeeds()
    {
        var stream = await _fx.Client.CsConvertCoordinateSystemCodeToWkt.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "CS.CONVERTCOORDINATESYSTEMCODETOWKT";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.CSCODE = "LL84";
        });
        var text = await StreamAssert.ToTextAsync(stream);
        Assert.NotEmpty(text);
    }

    [Fact]
    public async Task GeoBoundary_returns_geometry()
    {
        var text = await _fx.Client.GeoBoundary.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GEO.BOUNDARY";
            c.QueryParameters.VERSION = "4.0.0"; // Geo* operations are 4.0.0 only
            c.QueryParameters.GEOMETRY = "POLYGON ((30 10, 40 40, 20 40, 10 20, 30 10))";
            c.QueryParameters.FORMAT = "WKT";
        });
        Assert.False(string.IsNullOrEmpty(text));
        Assert.Contains("POLYGON", text!, StringComparison.OrdinalIgnoreCase);
    }
}
