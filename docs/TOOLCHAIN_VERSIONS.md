# Versions de la Chaîne d'Outils (Toolchain)

Ce document consigne précisément les versions de développement testées et validées pour la compilation complète de Jarvisol sur Windows.

| Outil / Composant | Rôle | Version Minimale Recommandée | Version Testée & Validée |
| :--- | :--- | :--- | :--- |
| **Windows OS** | Système d'exploitation hôte | Windows 10 64-bit (19041+) | Windows 11 64-bit (Build 26100) |
| **Git** | Gestionnaire de versions | 2.40.0+ | 2.55.0.windows.2 |
| **Flutter SDK** | Framework UI & moteur Dart | 3.24.0+ (channel stable) | 3.47.0 (channel stable, revision 4cf2416426) |
| **Dart SDK** | Compilateur & runtime Dart | 3.5.0+ | 3.13.0 (inclus dans Flutter) |
| **Visual Studio** | Environnement C++ Windows | 2022 (17.8+) | Community 2022 v17.14.37628.2 |
| **MSVC Toolset** | Compilateur C/C++ (cl.exe) | v143 (14.38+) | 14.44.35207 |
| **Windows SDK** | Headers et bibliothèques Windows | 10.0.19041.0 | 10.0.26100.0 (et 10.0.19041.0) |
| **CMake** | Système de génération de build | 3.28+ | 3.31.6-msvc6 (inclus dans VS C++) |
| **Ninja** | Moteur de compilation rapide | 1.11+ | 1.12.1 (inclus dans VS C++) |
| **Python** | Runtimes auxiliaires (optionnel) | 3.10+ | 3.11.15 |

## Remarques de compatibilité

1. **Flutter** : La baseline a été compilée avec Flutter 3.47.0 (Dart 3.13.0). Tout SDK Flutter 3.24+ sur canal stable supportant Windows desktop avec FFI est compatible.
2. **Visual Studio** : La charge de travail *"Développement Desktop en C++"* (Desktop development with C++) est requise avec les outils MSVC v143 et le SDK Windows 10 ou 11.
3. **CMake & Ninja** : Sont automatiquement installés et détectés s'ils sont cochés dans l'installeur Visual Studio.
