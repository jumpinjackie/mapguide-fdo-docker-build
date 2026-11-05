using MapGuide.MapAgent.Client;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

[Collection(MapAgentCollection.Name)]
public sealed class MappingTileTests
{
    private readonly MapAgentFixture _fx;

    public MappingTileTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task CreateRuntimeMap_succeeds()
    {
        var stream = await _fx.Client.CreateRuntimeMap.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "CREATERUNTIMEMAP";
            c.QueryParameters.VERSION = "4.0.0"; // supported: 2.6.0, 3.0.0, 4.0.0
            c.QueryParameters.MAPDEFINITION = MapAgentFixture.SampleMapDefinition;
        });
        var text = await StreamAssert.ToTextAsync(stream);
        Assert.NotEmpty(text);
    }

    [Fact]
    public async Task GetDefaultTileSizeX_succeeds()
    {
        var stream = await _fx.Client.GetDefaultTileSizeX.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETDEFAULTTILESIZEX";
            c.QueryParameters.VERSION = "3.0.0"; // supported: 1.0.0, 3.0.0
            c.QueryParameters.MAPDEFINITION = MapAgentFixture.SampleMapDefinition;
        });
        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
    }
}
