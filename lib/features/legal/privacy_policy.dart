/// The privacy policy, as data.
///
/// Pure Dart on purpose: the same constant is rendered by the in-app screen and
/// by the generator that writes the public web page, and neither rendering can
/// pull Flutter into the other's build. Google Play requires the policy at a
/// public URL; a reader on a plane requires it without one. Holding the text in
/// one place is what stops those two copies from disagreeing about what the app
/// does, which is the only failure mode of a privacy policy that actually
/// matters.
///
/// Every claim below is checkable against the code, and was: read-only health
/// access is `HealthGatewayImpl.requestAuthorization`, the photo never touching
/// disk is `microservice/app/routes.py`, and "no analytics" is the dependency
/// list in `pubspec.yaml`. Change what the app does and this file changes with
/// it.
library;

/// One titled block of the policy.
class PolicySection {
  const PolicySection({required this.title, required this.paragraphs});

  /// Shown as a heading, and used verbatim as the web page's anchor text.
  final String title;

  /// Body text, in order. Rendered one paragraph per block in both media.
  final List<String> paragraphs;
}

/// The policy itself.
class PrivacyPolicy {
  PrivacyPolicy._();

  /// Bump this whenever any text below changes. It is the only version marker
  /// a reader gets, and both renderings show it.
  static const String effectiveDate = '15 September 2026';

  /// Where data requests actually arrive. Published, so expect it to be
  /// scraped; that is the cost of naming a reachable human.
  static const String contactEmail = 'sg.18.personal@gmail.com';

  /// The app's name as it appears to a reader of the policy.
  static const String appName = 'Void Factor';

  static const List<PolicySection> sections = [
    PolicySection(
      title: 'THE SHORT VERSION',
      paragraphs: [
        'Your meals, your weigh-ins, your health readings and your AI provider '
            'key never leave this phone. Your email address and a short profile '
            'are stored with your account so they come back when you sign in '
            'again. Food photos pass through our server on the way to the AI '
            'provider you chose, and are never saved by us.',
        'There is no analytics, no advertising, and no tracking of any kind. '
            'Nothing here is sold or shared. The rest of this page is the '
            'detail behind those sentences.',
      ],
    ),
    PolicySection(
      title: 'WHAT YOUR ACCOUNT STORES',
      paragraphs: [
        'Signing in with an email link gives us the address you signed in with. '
            'Signing in with Google gives us that address plus the display name '
            'and profile picture Google chooses to share.',
        'Your profile is stored against your account: height, weight, age, '
            'gender, your weight goal and weekly rate, your daily calorie '
            'target, and any allergies you selected. It is readable and '
            'writable only by you, and it is what returns when you sign in on a '
            'new phone.',
        'We also store one session identifier, which is how signing in '
            'somewhere else signs you out here. It identifies a session, not a '
            'device or a location.',
      ],
    ),
    PolicySection(
      title: 'WHAT NEVER LEAVES THIS PHONE',
      paragraphs: [
        'Every meal you log and every weigh-in you record is written to a file '
            'on this device and is never uploaded. That is a deliberate trade: '
            'there is no sync between devices, and no copy of your food history '
            'exists anywhere but here. Settings → Privacy → Export is how you '
            'keep one.',
        'Your AI provider key is held in this device’s secure storage. It '
            'travels with a scan request so your provider can identify and bill '
            'you, and it is never written down on our server.',
      ],
    ),
    PolicySection(
      title: 'WHAT HAPPENS TO A FOOD PHOTO',
      paragraphs: [
        'When you scan a meal, the photo is sent over an encrypted connection '
            'to our server, held in memory, and passed straight on to the AI '
            'provider you chose — Google Gemini, OpenRouter or NVIDIA NIM '
            '— using your own key. It is never written to disk and never '
            'stored.',
        'From the moment it reaches your provider, their privacy policy governs '
            'it and this one does not. You chose that provider and supplied the '
            'key, so if it matters to you, read theirs before you scan '
            'anything.',
        'What comes back — a food name and a nutrition estimate — is '
            'saved on this phone with the rest of your log, and nowhere else.',
      ],
    ),
    PolicySection(
      title: 'HEALTH AND FITNESS DATA',
      paragraphs: [
        'If you connect Health Connect or Apple Health, the app asks for '
            'read-only access to steps, water, workouts and active energy. It '
            'cannot write to them and never requests permission to.',
        'Those readings are used on this device to work out what you burned, '
            'and they are never uploaded — not to us, not to anyone. '
            'Revoking the permission in your system settings stops the reading '
            'immediately.',
      ],
    ),
    PolicySection(
      title: 'THE ON-DEVICE MODEL',
      paragraphs: [
        'If you turn on the on-device model, the app downloads Gemma from '
            'Hugging Face once. After that it runs entirely on this phone, '
            'offline. The wording of your recommendations is generated here and '
            'no part of it is sent anywhere.',
        'The model only changes the phrasing. Which recommendations you see is '
            'worked out in the app either way, so declining the download costs '
            'you nothing but nicer sentences.',
      ],
    ),
    PolicySection(
      title: 'WHAT WE DO NOT DO',
      paragraphs: [
        'There is no analytics library, no crash reporting, no advertising and '
            'no third-party tracker in this app. Nothing profiles you and '
            'nothing follows you between apps.',
        'We do not sell, rent or share your data, and there is no third party '
            'we hand it to. You bring your own AI key and pay your provider '
            'directly, so there is no business here that your data could be '
            'the price of.',
      ],
    ),
    PolicySection(
      title: 'WHAT OUR SERVER RECORDS',
      paragraphs: [
        'The server that relays scan requests keeps ordinary web logs: the IP '
            'address a request came from, the time, which endpoint it reached, '
            'and the response status. They exist to keep the service running '
            'and to enforce the per-user rate limit.',
        'Those logs hold no photos, no food names and no health data, and they '
            'are discarded when the service is redeployed.',
      ],
    ),
    PolicySection(
      title: 'WHAT YOU CAN DO',
      paragraphs: [
        'Export writes a single file holding your profile, every meal and every '
            'weigh-in, and hands it to your share sheet. Import merges such a '
            'file back in, adding only what this phone does not already have, '
            'so running it twice changes nothing.',
        'Delete Account removes your account, your profile from our database, '
            'and every meal and weigh-in on this device. It cannot be undone, '
            'so export first if you want to keep a copy.',
        'You can remove your provider key at any time in Settings → API Key, '
            'and revoke health access in your system settings. Neither needs '
            'our permission.',
      ],
    ),
    PolicySection(
      title: 'CHILDREN',
      paragraphs: [
        'This app is not directed at children under 13 and we do not knowingly '
            'collect anything from them. If you believe a child has an account '
            'here, write to us and it will be deleted.',
      ],
    ),
    PolicySection(
      title: 'CHANGES AND CONTACT',
      paragraphs: [
        'If this policy changes, the effective date at the top changes with it, '
            'and the new text appears both here and in the app. There is no '
            'separate announcement, so check back if it matters to you.',
        'Questions, data requests, or anything you want deleted: '
            '$contactEmail.',
      ],
    ),
  ];
}
