# Groupes d’espaces V2

Groupes d’espaces V2 est un sélecteur de fenêtres pour macOS. Réunis dans un projet les fenêtres dont tu as besoin, même si elles se trouvent sur des bureaux différents ou en plein écran.

## Installer la version 2.0

Il faut un Mac Apple Silicon sous macOS 27.2 ou version ultérieure. [Télécharger le DMG](https://github.com/AmazighChahid/GroupesEspacesV2/releases/download/v2.0/GroupesEspacesV2-2.0.dmg)

1. Ouvre le DMG et glisse **Groupes d’espaces V2** dans **Applications**.
2. Lance l’app et autorise-la dans **Réglages Système → Confidentialité et sécurité → Accessibilité**.

L’app porte une signature de développement, sans notarisation Apple. Si macOS bloque le premier lancement, suis la procédure **Ouvrir quand même**. [Assistance Apple](https://support.apple.com/fr-fr/102445)

## Utiliser le sélecteur

- **⌥ Tab** ouvre le sélecteur. **↑** et **↓** ou le défilement vertical changent de projet. **←** et **→** sélectionnent une fenêtre, et **Entrée** l’ouvre.
- **⌘ F** ou la loupe cherche une fenêtre dans tous les espaces.
- **⌘ ,** ou le pignon au survol du nom ouvre l’éditeur. Glisse une fenêtre entre les projets ou clique sur **−** pour la déplacer dans **Sans projet**.
- Dans l’éditeur, double-clique sur un nom pour renommer un projet. La corbeille supprime le groupe en un clic.

## Compiler depuis les sources

Ouvre le projet dans Xcode avec le SDK macOS 27.2, ou exécute cette commande depuis la racine du dépôt.

~~~sh
./build.sh
~~~

Le script crée l’app dans le dossier build.
