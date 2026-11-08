# ProjectHop

<img src="docs/branding/projecthop-logo.png#gh-light-mode-only" alt="Logo ProjectHop" width="260">

ProjectHop est un sélecteur de fenêtres pour macOS. Réunis dans un projet les fenêtres dont tu as besoin, même si elles se trouvent sur des bureaux différents ou en plein écran.

![Bannière ProjectHop avec le logo Hop Arc bleu azur et le texte « Switch windows by project. »](docs/branding/projecthop-github-banner.png)

## Démonstration

### Changer de projet au trackpad

Ouvre le sélecteur avec **⌥ Tab**, puis fais défiler verticalement pour passer au projet suivant ou revenir au précédent.

![Capture animée du sélecteur ProjectHop. Un défilement vers le bas passe de Montage à Publication. Un défilement vers le haut revient à Montage.](docs/projecthop-defilement.gif)

[Voir la vidéo en 1080p](https://github.com/AmazighChahid/ProjectHop/releases/download/v2.0/ProjectHop-defilement.mp4)

### Présentation générale

![Démo animée du sélecteur. Le raccourci Option Tab rassemble les fenêtres d’un projet réparties sur plusieurs bureaux.](docs/projecthop-demo.gif)

[Voir la démo en 1080p avec le son](https://github.com/AmazighChahid/ProjectHop/releases/download/v2.0/GroupesEspacesV2-motion.mp4)

## Installer ProjectHop

Il faut un Mac Apple Silicon sous macOS 27.2 ou version ultérieure. Choisis une variante.

| Variante | Fonctionnement |
| --- | --- |
| [ProjectHop.dmg](https://github.com/AmazighChahid/ProjectHop/releases/latest/download/ProjectHop.dmg) | Version standard, avec activation directe des fenêtres. |
| [ProjectHop-Sandbox.dmg](https://github.com/AmazighChahid/ProjectHop/releases/latest/download/ProjectHop-Sandbox.dmg) | Version avec App Sandbox. Elle privilégie la méthode Spacewalk pour les transitions entre bureaux quand l’app cible a plusieurs fenêtres. |

Les deux DMG peuvent être installés côte à côte et leurs réglages sont séparés. Lance une seule variante à la fois pour utiliser le raccourci **⌥ Tab**.

1. Ouvre le DMG et glisse l’app dans **Applications**.
2. Lance l’app et autorise-la dans **Réglages Système → Confidentialité et sécurité → Accessibilité**.

Les deux variantes portent une signature Apple Development, sans notarisation. Si macOS bloque le premier lancement, suis la procédure **Ouvrir quand même**. [Assistance Apple](https://support.apple.com/fr-fr/102445)

## Utiliser le sélecteur

- **⌥ Tab** ouvre le sélecteur. **↑** et **↓** ou le défilement vertical changent de projet. **←** et **→** sélectionnent une fenêtre, et **Entrée** l’ouvre.
- **⌘ F** ou la loupe cherche une fenêtre dans tous les espaces.
- **⌘ ,** ou le pignon au survol du nom ouvre l’éditeur. Glisse une fenêtre entre les projets ou clique sur **−** pour la déplacer dans **Sans projet**.
- Dans l’éditeur, double-clique sur un nom pour renommer un projet. La corbeille supprime le groupe en un clic.

## Compiler depuis les sources

Ouvre `ProjectHop.xcodeproj` dans Xcode avec le SDK macOS 27.2, puis sélectionne le schéma **ProjectHop** ou **ProjectHop Sandbox**. Les deux cibles compilent les mêmes fichiers sous `Sources/` et utilisent la même version dans `Resources/Info.plist`. Le sandbox est activé dans la configuration de la cible Sandbox.

Pour préparer une mise à jour, compile les deux schémas en configuration **Release** depuis le même commit.

~~~sh
xcodebuild -scheme ProjectHop -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -scheme 'ProjectHop Sandbox' -configuration Release -destination 'generic/platform=macOS' \
    PRODUCT_BUNDLE_IDENTIFIER=fr.groupesespaces.v2.sandbox DEVELOPMENT_TEAM=32P437V988 build
~~~

Pour archiver la variante destinée à TestFlight, sélectionne **ProjectHop Sandbox** et **Product → Archive**. Le schéma reprend l’identifiant et l’équipe de signature de la version déjà envoyée à Apple. La commande de compilation ci-dessus remplace ces réglages uniquement pour le DMG GitHub, qui utilise son propre identifiant.

Le raccourci `./build.sh` reste disponible pour compiler la version standard dans `build/ProjectHop.app`.
