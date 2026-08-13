using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Tvoice.Windows.Sip;

public sealed record SipMessage(
    string StartLine,
    IReadOnlyDictionary<string, IReadOnlyList<string>> Headers,
    string Body)
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Regex HeaderName = new("^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", RegexOptions.Compiled);

    public int? StatusCode => StartLine.StartsWith("SIP/2.0 ", StringComparison.OrdinalIgnoreCase) &&
                              int.TryParse(StartLine.Split(' ').ElementAtOrDefault(1), out var status)
        ? status
        : null;

    public string? Method => StatusCode is null
        ? StartLine.Split(' ').FirstOrDefault()?.ToUpperInvariant()
        : null;

    public string? Header(string name)
    {
        if (Headers.TryGetValue(name, out var values)) return values.FirstOrDefault();
        var compact = name.ToLowerInvariant() switch
        {
            "via" => "v",
            "from" => "f",
            "to" => "t",
            "call-id" => "i",
            "contact" => "m",
            "content-length" => "l",
            "content-type" => "c",
            _ => null,
        };
        return compact is not null && Headers.TryGetValue(compact, out values)
            ? values.FirstOrDefault()
            : null;
    }

    public IReadOnlyList<string> HeaderValues(string name)
    {
        if (Headers.TryGetValue(name, out var values)) return values;
        var compact = name.ToLowerInvariant() switch
        {
            "via" => "v",
            "from" => "f",
            "to" => "t",
            "call-id" => "i",
            "contact" => "m",
            "content-length" => "l",
            "content-type" => "c",
            _ => null,
        };
        return compact is not null && Headers.TryGetValue(compact, out values)
            ? values
            : Array.Empty<string>();
    }

    public int? CSeqNumber =>
        int.TryParse(Header("CSeq")?.Split(' ').FirstOrDefault(), out var value) ? value : null;

    public string? CSeqMethod =>
        Header("CSeq")?.Split(' ', StringSplitOptions.RemoveEmptyEntries).ElementAtOrDefault(1)?.ToUpperInvariant();

    public static SipMessage? Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length is < 1 or > 65_535) return null;
        string text;
        try
        {
            text = StrictUtf8.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }

        var divider = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        var dividerLength = 4;
        if (divider < 0)
        {
            divider = text.IndexOf("\n\n", StringComparison.Ordinal);
            dividerLength = 2;
        }

        var head = divider < 0 ? text : text[..divider];
        var body = divider < 0 ? string.Empty : text[(divider + dividerLength)..];
        var lines = Regex.Split(head, "\r?\n");
        if (lines.Length is < 1 or > 256) return null;
        var startLine = lines[0].Trim();
        if (!ValidStartLine(startLine)) return null;

        var headers = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        string? previousName = null;
        foreach (var rawLine in lines.Skip(1))
        {
            if (rawLine.Length > 8192 || rawLine.Contains('\0')) return null;
            if ((rawLine.StartsWith(' ') || rawLine.StartsWith('\t')) && previousName is not null)
            {
                var previous = headers[previousName];
                previous[^1] = $"{previous[^1]} {rawLine.Trim()}";
                continue;
            }

            var colon = rawLine.IndexOf(':');
            if (colon <= 0) return null;
            var name = rawLine[..colon].Trim();
            if (!HeaderName.IsMatch(name)) return null;
            if (!headers.TryGetValue(name, out var values))
            {
                values = [];
                headers[name] = values;
            }
            values.Add(rawLine[(colon + 1)..].Trim());
            previousName = name;
        }

        var lengths = headers
            .Where(item => item.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) ||
                           item.Key.Equals("l", StringComparison.OrdinalIgnoreCase))
            .SelectMany(item => item.Value)
            .Select(value => int.TryParse(value, out var length) ? length : -1)
            .ToArray();
        if (lengths.Any(length => length < 0) || lengths.Distinct().Count() > 1) return null;
        if (lengths.FirstOrDefault(-1) is var declaredLength && declaredLength >= 0)
        {
            var bytes = StrictUtf8.GetBytes(body);
            if (bytes.Length < declaredLength) return null;
            body = StrictUtf8.GetString(bytes.AsSpan(0, declaredLength));
        }

        return new SipMessage(
            startLine,
            headers.ToDictionary(
                item => item.Key,
                item => (IReadOnlyList<string>)item.Value,
                StringComparer.OrdinalIgnoreCase),
            body);
    }

    private static bool ValidStartLine(string value)
    {
        if (value.Length > 1024 || value.Contains('\r') || value.Contains('\n')) return false;
        if (value.StartsWith("SIP/2.0 ", StringComparison.OrdinalIgnoreCase))
            return int.TryParse(value.Split(' ').ElementAtOrDefault(1), out var status) && status is >= 100 and <= 699;
        var parts = value.Split(' ');
        return parts.Length == 3 && Regex.IsMatch(parts[0], "^[A-Z]+$") &&
               parts[1].StartsWith("sip:", StringComparison.OrdinalIgnoreCase) && parts[2] == "SIP/2.0";
    }
}

public sealed record DigestChallenge(string Realm, string Nonce, string? Qop, string? Opaque, string Algorithm)
{
    private static readonly Regex Field = new(
        "([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|([^,\\s]+))",
        RegexOptions.Compiled);

    public static DigestChallenge? Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var source = value.StartsWith("Digest", StringComparison.OrdinalIgnoreCase)
            ? value[6..].Trim()
            : value.Trim();
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in Field.Matches(source))
            fields[match.Groups[1].Value] = match.Groups[2].Success
                ? match.Groups[2].Value
                : match.Groups[3].Value;
        if (!fields.TryGetValue("realm", out var realm) || !fields.TryGetValue("nonce", out var nonce))
            return null;
        fields.TryGetValue("qop", out var qopValues);
        var qop = qopValues?.Split(',').Select(item => item.Trim())
            .FirstOrDefault(item => item.Equals("auth", StringComparison.OrdinalIgnoreCase));
        fields.TryGetValue("opaque", out var opaque);
        return new DigestChallenge(
            realm,
            nonce,
            qop,
            opaque,
            fields.GetValueOrDefault("algorithm", "MD5"));
    }
}

public static class DigestAuthorization
{
    public static string Create(
        DigestChallenge challenge,
        string username,
        string password,
        string method,
        string uri,
        int nonceCount,
        string? cnonceOverride = null)
    {
        if (!challenge.Algorithm.Equals("MD5", StringComparison.OrdinalIgnoreCase))
            throw new NotSupportedException($"Unsupported SIP digest algorithm: {challenge.Algorithm}");
        EnsureSafe(username, challenge.Realm, challenge.Nonce, uri, challenge.Opaque ?? string.Empty);
        var nonceCountHex = nonceCount.ToString("x8", CultureInfo.InvariantCulture);
        var cnonce = cnonceOverride ?? SipValues.RandomHex(8);
        EnsureSafe(cnonce);
        var ha1 = Md5($"{username}:{challenge.Realm}:{password}");
        var ha2 = Md5($"{method}:{uri}");
        var response = challenge.Qop is not null
            ? Md5($"{ha1}:{challenge.Nonce}:{nonceCountHex}:{cnonce}:{challenge.Qop}:{ha2}")
            : Md5($"{ha1}:{challenge.Nonce}:{ha2}");

        var builder = new StringBuilder()
            .Append("Digest username=\"").Append(Quote(username)).Append('"')
            .Append(", realm=\"").Append(Quote(challenge.Realm)).Append('"')
            .Append(", nonce=\"").Append(Quote(challenge.Nonce)).Append('"')
            .Append(", uri=\"").Append(Quote(uri)).Append('"')
            .Append(", response=\"").Append(response).Append('"')
            .Append(", algorithm=MD5");
        if (challenge.Qop is not null)
        {
            builder.Append(", qop=").Append(challenge.Qop)
                .Append(", nc=").Append(nonceCountHex)
                .Append(", cnonce=\"").Append(Quote(cnonce)).Append('"');
        }
        if (challenge.Opaque is not null)
            builder.Append(", opaque=\"").Append(Quote(challenge.Opaque)).Append('"');
        return builder.ToString();
    }

    private static string Md5(string value) =>
        Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static string Quote(string value) => value.Replace("\\", "\\\\").Replace("\"", "\\\"");

    private static void EnsureSafe(params string[] values)
    {
        if (values.Any(value => value.Contains('\r') || value.Contains('\n')))
            throw new ArgumentException("SIP authentication value contains a line break.");
    }
}

public sealed record ViaMapping(string Address, int Port)
{
    public static ViaMapping? Parse(string? value)
    {
        if (value is null) return null;
        var address = Regex.Match(value, "(?:^|;)\\s*received=([^;,\\s]+)", RegexOptions.IgnoreCase)
            .Groups[1].Value.Trim('[', ']');
        var portText = Regex.Match(value, "(?:^|;)\\s*rport\\s*=\\s*(\\d+)", RegexOptions.IgnoreCase)
            .Groups[1].Value;
        return address.Length > 0 && int.TryParse(portText, out var port) && port is >= 1 and <= 65535
            ? new ViaMapping(address, port)
            : null;
    }
}

public static class SipValues
{
    public static string RandomHex(int bytes) => Convert.ToHexString(RandomNumberGenerator.GetBytes(bytes)).ToLowerInvariant();
    public static string NewBranch() => $"z9hG4bK-{RandomHex(10)}";
}

public static class G711
{
    public static byte EncodeAlaw(short sample)
    {
        var pcm = sample >> 3;
        int mask;
        if (pcm >= 0) mask = 0xD5;
        else { mask = 0x55; pcm = -pcm - 1; }
        pcm = Math.Min(pcm, 4095);
        var segment = pcm switch
        {
            > 2047 => 7, > 1023 => 6, > 511 => 5, > 255 => 4,
            > 127 => 3, > 63 => 2, > 31 => 1, _ => 0,
        };
        var encoded = segment < 2
            ? (segment << 4) | ((pcm >> 1) & 0x0F)
            : (segment << 4) | ((pcm >> segment) & 0x0F);
        return (byte)(encoded ^ mask);
    }

    public static short DecodeAlaw(byte value)
    {
        var a = value ^ 0x55;
        var sample = (a & 0x0F) << 4;
        var segment = (a & 0x70) >> 4;
        sample += 8;
        if (segment >= 1) sample += 0x100;
        if (segment > 1) sample <<= segment - 1;
        return (short)((a & 0x80) != 0 ? sample : -sample);
    }

    public static byte EncodeUlaw(short sample)
    {
        var pcm = (int)sample;
        int mask;
        if (pcm < 0) { pcm = -pcm; mask = 0x7F; }
        else mask = 0xFF;
        pcm = Math.Min(pcm + 0x84, 32635);
        var exponent = 7;
        for (var test = 0x4000; exponent > 0 && (pcm & test) == 0; exponent--, test >>= 1) { }
        var mantissa = (pcm >> (exponent + 3)) & 0x0F;
        return (byte)(((exponent << 4) | mantissa) ^ mask);
    }

    public static short DecodeUlaw(byte value)
    {
        var u = ~value & 0xFF;
        var sign = u & 0x80;
        var exponent = (u >> 4) & 0x07;
        var mantissa = u & 0x0F;
        var sample = ((mantissa << 3) + 0x84) << exponent;
        sample -= 0x84;
        return (short)(sign != 0 ? -sample : sample);
    }
}
