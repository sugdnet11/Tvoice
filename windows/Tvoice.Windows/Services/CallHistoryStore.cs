using System.IO;
using System.Text.Json;
using Tvoice.Windows.Models;

namespace Tvoice.Windows.Services;

public sealed class CallHistoryStore
{
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Tvoice", "call-history.json");
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public IReadOnlyList<CallHistoryEntry> Load()
    {
        try
        {
            if (!File.Exists(_path)) return [];
            return JsonSerializer.Deserialize<List<CallHistoryEntry>>(File.ReadAllText(_path), _json) ?? [];
        }
        catch { return []; }
    }

    public void Save(IEnumerable<CallHistoryEntry> entries)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(entries.Take(200), _json));
        }
        catch { }
    }
}
