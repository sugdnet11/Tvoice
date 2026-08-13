using System.Globalization;
using System.Windows.Data;

namespace Tvoice.Windows.Services;

public sealed class MessageStatusConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "sent" => "  ✓",
            "delivered" => "  ✓✓",
            "read" => "  ✓✓",
            _ => string.Empty,
        };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        System.Windows.Data.Binding.DoNothing;
}
