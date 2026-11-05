using System.Text;
using Xunit;

namespace MapGuide.MapAgent.OpenApi.Tests;

/// <summary>
/// Helpers for turning the <see cref="Stream"/> a generated operation returns into assertable
/// data, and for recognising image streams by their magic bytes. The rendering operations stream
/// binary images whose media type is image/&lt;format&gt;; the signature check is what proves the body
/// really is an image and not, say, an XML error document served with a 200.
/// </summary>
internal static class StreamAssert
{
    public static async Task<byte[]> ToBytesAsync(Stream? stream, CancellationToken ct = default)
    {
        Assert.NotNull(stream);
        using var buffer = new MemoryStream();
        await stream!.CopyToAsync(buffer, ct).ConfigureAwait(false);
        return buffer.ToArray();
    }

    public static async Task<string> ToTextAsync(Stream? stream, CancellationToken ct = default)
        => Encoding.UTF8.GetString(await ToBytesAsync(stream, ct).ConfigureAwait(false));

    public static bool IsPng(ReadOnlySpan<byte> b) =>
        b.Length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A;

    public static bool IsGif(ReadOnlySpan<byte> b) =>
        b.Length >= 6 &&
        b[0] == (byte)'G' && b[1] == (byte)'I' && b[2] == (byte)'F' &&
        b[3] == (byte)'8' && (b[4] == (byte)'7' || b[4] == (byte)'9') && b[5] == (byte)'a';

    public static bool IsJpeg(ReadOnlySpan<byte> b) =>
        b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

    public static bool IsTiff(ReadOnlySpan<byte> b) =>
        b.Length >= 4 &&
        ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
         (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A));

    /// <summary>Asserts the bytes begin with the signature for the named format.</summary>
    public static void AssertIsImageFormat(string format, byte[] bytes)
    {
        var ok = format.ToUpperInvariant() switch
        {
            "PNG" or "PNG8" => IsPng(bytes),
            "GIF" => IsGif(bytes),
            "JPG" or "JPEG" => IsJpeg(bytes),
            "TIFF" => IsTiff(bytes),
            _ => false,
        };
        Assert.True(ok, $"Body is not a valid {format} image. First bytes: {Hex(bytes)}");
    }

    private static string Hex(ReadOnlySpan<byte> b)
    {
        var n = Math.Min(b.Length, 8);
        var sb = new StringBuilder(n * 3);
        for (var i = 0; i < n; i++)
        {
            sb.Append(b[i].ToString("X2")).Append(' ');
        }
        return sb.ToString().TrimEnd();
    }
}
