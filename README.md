# 🌟 SmartGuide Vision

Welcome to the **SmartGuide Vision** project! This repository contains a multi-component system featuring Flutter-based mobile applications and a Raspberry Pi module for obstacle tracking, vision, and hardware interfacing.

## 📂 Repository Structure

- 📱 **`dourbiya/`**: The primary Flutter mobile application (UI, Map integrations, TTS).
- 📱 **`flutter/`**: The secondary SmartGuide Flutter application module.
- 🍓 **`pi/`**: Python-based backend for Raspberry Pi, handling WebSocket communication, vision scripts (obstacle tracking), and HMI (Human-Machine Interface) tasks.

---

## 🚀 Getting Started (Setup Steps)

Follow these instructions to set up the different components of the project locally.

### 1️⃣ Mobile Application (Flutter)

**Prerequisites:** Ensure you have the [Flutter SDK](https://flutter.dev/docs/get-started/install) installed.

```bash
# Navigate to the main app directory
cd dourbiya

# Install all Flutter dependencies
flutter pub get

# Run the application (ensure a physical device or emulator is connected)
flutter run
```

*(Note: The same steps apply for the `flutter/` directory if you need to run that specific app module).*

### 2️⃣ Raspberry Pi Module (Python)

**Prerequisites:** Python 3.8+ and a Raspberry Pi environment (or local simulation).

```bash
# Navigate to the Pi module
cd pi

# Make the install script executable and run it to install dependencies
chmod +x scripts/install.sh
./scripts/install.sh

# Start the core WebSocket server
python core/websocket_server.py

# (Optional) Run the vision/obstacle tracker script
python vision/obstacle_tracker.py
```

---

## 🛠 Built With

* **[Flutter & Dart](https://flutter.dev/)** - UI Toolkit for cross-platform mobile apps.
* **[Python](https://www.python.org/)** - For backend, WebSocket communication, and vision processing.
* **Raspberry Pi** - Hardware execution environment for real-world interactions.