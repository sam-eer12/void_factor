# Void Factor

A Flutter-based nutrition & food tracking application with AI-powered food recognition, Firebase backend, and a Python (FastAPI) microservice for image analysis.

---

## Folder Structure

```
void_factor/
├── android/                        # Android platform-specific code
├── ios/                            # iOS platform-specific code
│
├── lib/                            #  Main Flutter application source
│   ├── main.dart                   # App entry point
│   │
│   ├── app/                        # App-level configuration
│   │   ├── app.dart                # Root MaterialApp widget (MonolithApp)
│   │   └── routes.dart             # Named route definitions & navigation
│   │
│   ├── screens/                    # Feature screens (organized by domain)
│   │   ├── auth/                   # Authentication flow
│   │   │   ├── login_screen.dart         # Login page
│   │   │   ├── signup_screen.dart        # Registration page
│   │   │   └── otp_screen.dart           # OTP verification page
│   │   │
│   │   ├── onboarding/             # First-time user setup
│   │   │   └── profile_init_screen.dart  # Profile initialization
│   │   │
│   │   ├── dashboard/              # Main home screen
│   │   │   └── dashboard_screen.dart     # Dashboard with nutrition overview
│   │   │
│   │   ├── vision/                 # AI food recognition
│   │   │   └── ai_vision_screen.dart     # Camera-based food analysis
│   │   │
│   │   ├── food_log/               # Manual food logging
│   │   │   └── manual_food_log_screen.dart  # Manual nutrition entry
│   │   │
│   │   ├── donation/               # Donation / support
│   │   │   └── donation_screen.dart      # Donation page
│   │   │
│   │   ├── stats/                  # Statistics & projections
│   │   │   └── projections_screen.dart   # Nutrition projections & charts
│   │   │
│   │   └── settings/               # App settings
│   │       └── settings_screen.dart      # User preferences & config
│   │
│   ├── theme/                      # Design system
│   │   └── monolith_theme.dart     # App-wide theme (colors, typography)
│   │
│   └── widgets/                    # Reusable UI components
│       ├── monolith_bottom_nav.dart     # Custom bottom navigation bar
│       ├── monolith_button.dart         # Styled button component
│       ├── monolith_card.dart           # Card component
│       ├── monolith_drawer.dart         # Navigation drawer
│       └── monolith_text_field.dart     # Styled text input field
│
├── assets/                         # Static assets
│   └── images/                     # Image assets
│       ├── icon1.png               # App icon variant 1
│       ├── icon2.jpg               # App icon variant 2
│       ├── icon3.jpg               # App icon variant 3
│       └── screen.png              # Screenshot / splash image
│
├── microservice/                   # Python FastAPI backend
│   ├── app.py                      # API endpoints (Gemini & OpenRouter)
│   ├── Dockerfile                  # Container configuration
│   ├── requirements.txt            # Python dependencies
│   ├── .env                        # Environment variables (API keys)
│   └── .gitignore                  # Microservice-specific ignores
│
├── nginx/                          # Reverse proxy config
│   └── nginx.conf                  # Nginx configuration
│
├── test/                           # Tests
│   └── widget_test.dart            # Widget unit tests
│
├── pubspec.yaml                    # Flutter dependencies & project config
├── pubspec.lock                    # Locked dependency versions
├── analysis_options.yaml           # Dart linting rules
├── docker-compose.yml              # Docker Compose orchestration
├── .gitignore                      # Git ignore rules
└── README.md                       # This file
```

---

## Features

- **AI Food Recognition** — Snap a photo and get instant nutritional analysis via Gemini AI
- **Manual Food Logging** — Track meals with manual calorie & macro entry
- **Dashboard** — At-a-glance nutrition overview and daily progress
- **Projections & Stats** — Visualize nutrition trends and health projections
- **Authentication** — Email/OTP and Google Sign-In via Firebase Auth
- **Cloud Sync** — Firestore-backed data persistence and Firebase Storage
- **Donations** — In-app donation/support page
- **Settings** — Customizable user preferences

---

## Tech Stack

| Layer          | Technology                                       |
| -------------- | ------------------------------------------------ |
| **Frontend**   | Flutter (Dart), Riverpod for state management    |
| **Backend**    | FastAPI (Python), Gemini AI, OpenRouter           |
| **Database**   | Cloud Firestore                                  |
| **Auth**       | Firebase Auth (Email/OTP, Google Sign-In)         |
| **Storage**    | Firebase Storage                                 |
| **Infra**      | Docker, Nginx reverse proxy                      |
| **AI/ML**      | Google Gemini API, Flutter Gemma (on-device)      |

---

## 🚀 Getting Started

### Prerequisites

- Flutter SDK `>=3.11.5`
- Dart SDK
- Android Studio / Xcode
- Python 3.10+ (for microservice)
- Docker (optional, for containerized backend)

### Flutter App

```bash
# Clone the repository
git clone https://github.com/your-username/void_factor.git
cd void_factor

# Install dependencies
flutter pub get

# Run the app
flutter run
```

### Microservice

```bash
cd microservice

# Create virtual environment
python -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Set up environment variables
cp .env.example .env
# Edit .env with your API keys

# Run the server
python app.py
```

### Docker (Full Stack)

```bash
docker-compose up --build
```

---

## Environment Variables

The microservice requires the following keys in `microservice/.env`:

| Variable           | Description              |
| ------------------ | ------------------------ |
| `x_gemini_key`     | Google Gemini API key    |
| `x_openrouter_key` | OpenRouter API key       |

---

## License

This project is private and not published to pub.dev.
