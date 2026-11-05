using MapGuide.MapAgent.Client;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

[Collection(MapAgentCollection.Name)]
public sealed class ResourceTests
{
    private readonly MapAgentFixture _fx;

    public ResourceTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task EnumerateResources_succeeds()
    {
        var stream = await _fx.Client.EnumerateResources.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "ENUMERATERESOURCES";
            c.QueryParameters.VERSION = "4.0.0";
            c.QueryParameters.RESOURCEID = "Library://Samples/Sheboygan/";
            c.QueryParameters.DEPTH = -1;
        });
        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
    }
}
