/// Where support money actually goes.
///
/// One place, on purpose. The donation screen previously showed an
/// `Icons.qr_code_2` glyph captioned "UPI QR CODE" and a `donate@monolith`
/// handle that belongs to nobody, which is worse than having no donation screen:
/// a user who scans it and sends money sends it nowhere.
///
/// Every value here is empty until filled in. The screen reads [isConfigured]
/// and says plainly that support is not set up yet rather than rendering a
/// plausible-looking destination that does not exist. Filling these two
/// constants in is the whole activation step.
class SupportLinks {
  SupportLinks._();

  /// The UPI virtual payment address, e.g. `name@okhdfcbank`.
  static const String upiVpa =
      String.fromEnvironment('SUPPORT_UPI_VPA', defaultValue: '');

  /// Shown by the payer's UPI app as the recipient. Ignored when [upiVpa] is
  /// empty.
  static const String upiPayeeName = 'Void Factor';

  /// The name in `buymeacoffee.com/<username>`.
  static const String buyMeACoffeeUsername =
      String.fromEnvironment('SUPPORT_BMC_USERNAME', defaultValue: '');

  static bool get hasUpi => upiVpa.trim().isNotEmpty;
  static bool get hasBuyMeACoffee => buyMeACoffeeUsername.trim().isNotEmpty;
  static bool get isConfigured => hasUpi || hasBuyMeACoffee;

  /// The `upi://pay` deep link, per the NPCI URL specification.
  ///
  /// No amount is included: a donation the giver cannot size is a donation most
  /// people abandon, and every UPI app lets them type one.
  ///
  /// This same string is what the QR encodes, so the scanned and tapped paths
  /// cannot disagree about where the money goes.
  static Uri get upiUri => Uri(
        scheme: 'upi',
        host: 'pay',
        queryParameters: {
          'pa': upiVpa.trim(),
          'pn': upiPayeeName,
          'cu': 'INR',
        },
      );

  static Uri get buyMeACoffeeUri =>
      Uri.parse('https://buymeacoffee.com/${buyMeACoffeeUsername.trim()}');
}
