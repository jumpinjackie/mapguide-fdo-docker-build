using MapGuide.MapAgent.Client;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

[Collection(MapAgentCollection.Name)]
public sealed class FeatureTests
{
    private readonly MapAgentFixture _fx;

    public FeatureTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task GetFeatureProviders_lists_known_providers()
    {
        var stream = await _fx.Client.GetFeatureProviders.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETFEATUREPROVIDERS";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.FORMAT = "text/xml";
        });
        var text = await StreamAssert.ToTextAsync(stream);
        Assert.Contains("OSGeo.SDF", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task GetSchemas_returns_schema_list()
    {
        var stream = await _fx.Client.GetSchemas.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETSCHEMAS";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.RESOURCEID = MapAgentFixture.SampleFeatureSource;
        });
        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
    }

    [Fact]
    public async Task DescribeFeatureSchema_succeeds()
    {
        var stream = await _fx.Client.DescribeFeatureSchema.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "DESCRIBEFEATURESCHEMA";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.RESOURCEID = MapAgentFixture.SampleFeatureSource;
        });
        var text = await StreamAssert.ToTextAsync(stream);
        Assert.NotEmpty(text);
    }
}
