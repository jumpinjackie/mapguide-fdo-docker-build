using MapGuide.MapAgent.Client;
using MapGuide.MapAgent.Client.CreateSession;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

[Collection(MapAgentCollection.Name)]
public sealed class SessionAndSiteTests
{
    private readonly MapAgentFixture _fx;

    public SessionAndSiteTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task CreateSession_returns_a_session_id()
    {
        var session = await _fx.Client.CreateSession.PostAsync(new CreateSessionPostRequestBody
        {
            OPERATION = CreateSessionPostRequestBody_OPERATION.CREATESESSION,
            VERSION = CreateSessionPostRequestBody_VERSION.OneZeroZero,
            USERNAME = _fx.User,
            PASSWORD = _fx.Password,
            LOCALE = "en",
        });

        Assert.False(string.IsNullOrWhiteSpace(session));
    }

    [Fact]
    public async Task GetSiteStatus_succeeds()
    {
        var stream = await _fx.Client.GetSiteStatus.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETSITESTATUS";
            c.QueryParameters.VERSION = "4.0.0";
        });
        var bytes = await StreamAssert.ToBytesAsync(stream);
        Assert.NotEmpty(bytes);
    }

    [Fact]
    public async Task GetSiteVersion_succeeds()
    {
        var stream = await _fx.Client.GetSiteVersion.GetAsync(c =>
        {
            c.QueryParameters.OPERATION = "GETSITEVERSION";
            c.QueryParameters.VERSION = "4.0.0";
        });
        var text = await StreamAssert.ToTextAsync(stream);
        Assert.NotEmpty(text);
    }
}
