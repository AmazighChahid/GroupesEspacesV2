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

## Installer la version 2.0

Il faut un Mac Apple Silicon sous macOS 27.2 ou version ultérieure. [Télécharger le DMG](https://github.com/AmazighChahid/ProjectHop/releases/download/v2.0/GroupesEspacesV2-2.0.dmg)

1. Ouvre le DMG et glisse **Groupes d’espaces V2**, le nom de ProjectHop dans la version 2.0, dans **Applications**.
2. Lance l’app et autorise-la dans **Réglages Système → Confidentialité et sécurité → Accessibilité**.

L’app porte une signature de développement, sans notarisation Apple. Si macOS bloque le premier lancement, suis la procédure **Ouvrir quand même**. [Assistance Apple](https://support.apple.com/fr-fr/102445)

## Utiliser le sélecteur

- **⌥ Tab** ouvre le sélecteur. **↑** et **↓** ou le défilement vertical changent de projet. **←** et **→** sélectionnent une fenêtre, et **Entrée** l’ouvre.
- **⌘ F** ou la loupe cherche une fenêtre dans tous les espaces.
- **⌘ ,** ou le pignon au survol du nom ouvre l’éditeur. Glisse une fenêtre entre les projets ou clique sur **−** pour la déplacer dans **Sans projet**.
- Dans l’éditeur, double-clique sur un nom pour renommer un projet. La corbeille supprime le groupe en un clic.

## Compiler depuis les sources

Ouvre `ProjectHop.xcodeproj` dans Xcode avec le SDK macOS 27.2, ou exécute cette commande depuis la racine du dépôt.

~~~sh
./build.sh
~~~

Le script crée `build/ProjectHop.app`.
