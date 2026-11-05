using System.Net;
using System.Text;
using Microsoft.Kiota.Abstractions;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

/// <summary>
/// Exercises the two error shapes the mapagent actually emits, matching the spec's
/// <c>UnauthorizedError</c> and <c>MapAgentError</c> responses:
///
///   401  the Basic challenge, with an empty-ish text/plain body
///   559  every handler exception, as a text/html page (HTTP_STATUS_MG_ERROR)
///
/// Both reach the generated client as an <see cref="ApiException"/> whose
/// <see cref="ApiException.ResponseStatusCode"/> carries the raw status, because the error bodies
/// are scalars Kiota cannot turn into a model. The wire shape is asserted separately with plain
/// HttpClient so the spec's documented Content-Type is covered too.
/// </summary>
[Collection(MapAgentCollection.Name)]
public sealed class ErrorModelTests
{
    private readonly MapAgentFixture _fx;

    public ErrorModelTests(MapAgentFixture fx) => _fx = fx;

    [Fact]
    public async Task Anonymous_request_to_protected_operation_throws_401()
    {
        var (client, http) = _fx.CreateUnauthenticatedClient();
        try
        {
            var ex = await Assert.ThrowsAsync<ApiException>(() =>
                client.GetSiteInfo.GetAsync(c =>
                {
                    c.QueryParameters.OPERATION = "GETSITEINFO";
                    c.QueryParameters.VERSION = "4.0.0";
                }));

            Assert.Equal(401, ex.ResponseStatusCode);

            // The wire contract: a Basic challenge for the product realm, not a body payload.
            using var response = await http.GetAsync(
                $"{_fx.Endpoint}?OPERATION=GETSITEINFO&VERSION=4.0.0");

            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
            Assert.Equal("text/plain", response.Content.Headers.ContentType?.MediaType);
            Assert.Contains(
                "Basic",
                response.Headers.WwwAuthenticate.ToString(),
                StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            http.Dispose();
        }
    }

    [Fact]
    public async Task Handler_exception_throws_559_with_an_html_body()
    {
        // A syntactically valid but non-existent resource id makes the handler raise
        // MgResourceNotFoundException; the agent maps every Mg exception to 559.
        var ex = await Assert.ThrowsAsync<ApiException>(() =>
            _fx.Client.EnumerateResources.GetAsync(c =>
            {
                c.QueryParameters.OPERATION = "ENUMERATERESOURCES";
                c.QueryParameters.VERSION = "4.0.0";
                c.QueryParameters.RESOURCEID = "Library://Bogus/Bogus/";
            }));

        Assert.Equal(559, ex.ResponseStatusCode);

        // The wire contract: 559 carrying an HTML page whose title is the exception code.
        var (status, contentType, body) = await _fx.GetRawAsync(
            "ENUMERATERESOURCES",
            new Dictionary<string, string>
            {
                ["VERSION"] = "4.0.0",
                ["RESOURCEID"] = "Library://Bogus/Bogus/",
            });

        Assert.Equal(559, (int)status);
        Assert.Equal("text/html", contentType);
        Assert.Contains(
            "MgResourceNotFoundException",
            Encoding.UTF8.GetString(body),
            StringComparison.Ordinal);
    }
}
