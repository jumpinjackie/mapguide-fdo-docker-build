using System.Net;
using System.Net.Http.Headers;
using System.Text;
using MapGuide.MapAgent.Client;
using Microsoft.Kiota.Abstractions.Authentication;
using Microsoft.Kiota.Http.HttpClientLibrary;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

/// <summary>
/// Shared fixture: builds a Kiota-generated <see cref="MapAgentClient"/> pointed at a running
/// MapGuide MapAgent. The endpoint and credentials come from the environment so the same suite
/// runs against a locally installed server or the CI one:
///
///   MG_MAPAGENT_URL  default http://localhost:8018/mapguide/mapagent/mapagent.fcgi
///   MG_USER          default Administrator
///   MG_PASS          default admin
///
/// Authentication uses HTTP Basic against the mapagent (CgiAgent accepts it); the raw helper
/// below also uses Basic so both paths behave the same way.
/// </summary>
public sealed class MapAgentFixture : IDisposable
{
    /// <summary>The Sheboygan sample map installed with a default MapGuide server.</summary>
    public const string SampleMapDefinition =
        "Library://Samples/Sheboygan/Maps/Sheboygan.MapDefinition";

    /// <summary>The sample feature source used by the Sheboygan map.</summary>
    public const string SampleFeatureSource =
        "Library://Samples/Sheboygan/Data/Parcels.FeatureSource";

    /// <summary>A Sheboygan layer definition that renders a legend (the Parcels layer yields none).</summary>
    public const string SampleLayerDefinition =
        "Library://Samples/Sheboygan/Layers/Soils.LayerDefinition";

    public HttpClient Http { get; }
    public MapAgentClient Client { get; }
    public string Endpoint { get; }
    public string User { get; }
    public string Password { get; }

    public MapAgentFixture()
    {
        Endpoint = Environment.GetEnvironmentVariable("MG_MAPAGENT_URL")
                   ?? "http://localhost:8018/mapguide/mapagent/mapagent.fcgi";
        User = Environment.GetEnvironmentVariable("MG_USER") ?? "Administrator";
        Password = Environment.GetEnvironmentVariable("MG_PASS") ?? "admin";

        Http = new HttpClient { Timeout = TimeSpan.FromSeconds(180) };
        var token = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{User}:{Password}"));
        Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", token);

        var adapter = new HttpClientRequestAdapter(
            new AnonymousAuthenticationProvider(),
            httpClient: Http);
        adapter.BaseUrl = Endpoint;
        Client = new MapAgentClient(adapter);
    }

    /// <summary>
    /// Issues a raw GET straight at the mapagent's bare endpoint (no path decoration) and returns
    /// the status, media type and body bytes. This is deliberately independent of the generated
    /// client's URL building, so it can assert on Content-Type headers - which the Kiota adapter
    /// consumes - and prove the server-side stream is a real image.
    /// </summary>
    public async Task<(HttpStatusCode Status, string? ContentType, byte[] Body)> GetRawAsync(
        string operation, IReadOnlyDictionary<string, string> parameters,
        CancellationToken ct = default)
    {
        var query = new StringBuilder();
        void Add(string key, string value)
        {
            query.Append(query.Length == 0 ? '?' : '&');
            query.Append(Uri.EscapeDataString(key));
            query.Append('=');
            query.Append(Uri.EscapeDataString(value));
        }

        Add("OPERATION", operation);
        foreach (var kv in parameters)
        {
            Add(kv.Key, kv.Value);
        }

        var url = Endpoint + query;
        using var response = await Http.GetAsync(url, ct).ConfigureAwait(false);
        var mediaType = response.Content.Headers.ContentType?.MediaType;
        var body = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        return (response.StatusCode, mediaType, body);
    }

    /// <summary>
    /// Creates a second generated client whose HttpClient carries no Authorization header, so the
    /// mapagent answers the way it does for an anonymous caller. Authentication here comes from
    /// the HttpClient's default header (not the adapter's provider), so dropping the header is
    /// what makes the request anonymous. The caller owns the returned <see cref="HttpClient"/>.
    /// </summary>
    public (MapAgentClient Client, HttpClient Http) CreateUnauthenticatedClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        var adapter = new HttpClientRequestAdapter(
            new AnonymousAuthenticationProvider(),
            httpClient: http);
        adapter.BaseUrl = Endpoint;
        return (new MapAgentClient(adapter), http);
    }

    public void Dispose() => Http.Dispose();
}

[CollectionDefinition(Name)]
public sealed class MapAgentCollection : ICollectionFixture<MapAgentFixture>
{
    public const string Name = "mapagent";
}
