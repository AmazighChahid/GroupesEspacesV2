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

Les deux variantes 2.2.2 ciblent macOS 26.0 ou version ultérieure sur Mac Apple Silicon. Le carrousel et le passage entre bureaux restent à valider sur Tahoe.

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
- Le bouton **✦** de l’éditeur propose des noms pour les fenêtres qui n’ont pas encore de libellé personnalisé. Le menu contextuel permet de renommer une seule fenêtre avec Apple Intelligence. Dans la barre des menus, **Nommer les nouvelles fenêtres** active le nommage des fenêtres ouvertes par la suite.

## Stack technique

| Couche | Technologies et rôle |
| --- | --- |
| Application macOS | **Swift 6**. **AppKit** gère les panneaux, le sélecteur et le dock latéral. **SwiftUI** sert notamment à l’éditeur de projets et à l’écran de configuration. **Combine** propage l’état du nommage vers la barre des menus. |
| Rendu | Un pont **Objective-C** charge les couches internes du Dock, dont `BezelIconListLayer`. **Core Animation** compose le carrousel et son matériau Liquid Glass. |
| Entrées et fenêtres | **Core Graphics** capte **⌥ Tab** avec `CGEventTap` et lit l’inventaire de WindowServer. **AppKit** fournit les processus et l’app au premier plan. **Accessibility** (`AXUIElement`) permet de lire un titre, de relever une fenêtre précise ou d’actionner son bouton de fermeture. |
| Spaces | **SkyLight** et des symboles privés de Core Graphics fournissent les bureaux, les espaces plein écran et la répartition des fenêtres par écran. Pour certaines transitions, ProjectHop envoie au Dock un geste synthétique adapté de **Spacewalk**. |
| Nommage et stockage | **Foundation Models** utilise le modèle de langage local d’Apple Intelligence. Les projets, affectations et ordres sont conservés dans `UserDefaults`. Les libellés personnalisés sont enregistrés dans le dossier local `Application Support`. |

Les deux variantes partagent le même code. Le rendu du carrousel et la gestion des Spaces dépendent d’interfaces internes à macOS. Une mise à jour du système peut donc modifier leur comportement. [Pont de rendu du Dock](Sources/DockRenderer/DockRenderer.m) · [Gestion des Spaces](Sources/ProjectHop/SpaceSystem.swift)

## Comment ProjectHop identifie les fenêtres

1. **Inventorier.** ProjectHop part de la liste WindowServer et la rapproche des applications lancées. Il filtre notamment les surfaces auxiliaires et les fenêtres enfants. Les attributs WindowServer permettent de conserver dans l’inventaire les fenêtres pertinentes, y compris certaines fenêtres minimisées ou masquées.
2. **Localiser.** SkyLight relie chaque fenêtre à ses Spaces. ProjectHop utilise les identifiants des fenêtres du plein écran et de Split View lorsqu’ils sont disponibles. Quand une fenêtre apparaît dans plusieurs Spaces, l’app privilégie le plein écran, puis le bureau actif, puis un autre bureau correspondant.
3. **Identifier.** La clé utilisée pour les affectations et les libellés combine le **PID**, la **date de lancement du processus** et le **`CGWindowID`**. Deux fenêtres d’une même app qui portent le même titre restent deux cibles distinctes. La date de lancement limite les confusions quand macOS réutilise un PID. Cette clé identifie une fenêtre ouverte dans la session en cours.
4. **Classer et chercher.** Une affectation manuelle à un projet prime sur l’association éventuelle du Space au projet. Le classement change la liste dans le sélecteur. La destination d’un basculement reste le Space remonté par WindowServer. La recherche combine le nom de l’app, le titre disponible et le libellé personnalisé.

[Inventaire et clé des fenêtres](Sources/ProjectHop/WindowCatalog.swift) · [Affectations et localisation](Sources/ProjectHop/GroupStore.swift) · [Recherche](Sources/ProjectHop/NativeSwitcher.swift)

## Comment ProjectHop ouvre la bonne fenêtre

Au moment de la sélection, ProjectHop relit l’inventaire pour vérifier que la fenêtre existe encore et retrouver son Space actuel. Sur la version standard, l’app peut demander une activation ciblée par PID et identifiant de fenêtre. Elle peut aussi retrouver l’élément Accessibility correspondant au `CGWindowID`, restaurer une fenêtre minimisée et la relever avec `AXRaise`. Si la liste Accessibility omet une fenêtre située sur un autre Space, ProjectHop essaie de résoudre son élément par jeton Accessibility, avec une recherche limitée dans le temps.

Sur la version Sandbox, ProjectHop privilégie **Spacewalk** pour atteindre une fenêtre non minimisée située sur un autre Space lorsque son app a plusieurs fenêtres. Le geste synthétique est adressé au Dock, puis ProjectHop attend que WindowServer signale le bon Space. La confirmation repose sur l’app au premier plan et l’identifiant de sa première fenêtre visible, ou sur l’identifiant de l’unique fenêtre du Space plein écran.

Le code vérifie le bureau actif et la fenêtre obtenue après le basculement. Dans la version standard, il compare aussi l’identifiant du focus Accessibility quand celui-ci est disponible. Si macOS donne le focus à une autre fenêtre, ProjectHop traite ce résultat comme un échec de sélection. Une nouvelle sélection annule le basculement précédent. Le test d’intégration vérifie le Space actif, le PID de l’app au premier plan et l’identifiant de la fenêtre obtenue sur une séquence de trois sélections.

[Séquence d’activation](Sources/ProjectHop/App.swift) · [Résolution Accessibility](Sources/ProjectHop/WindowFocus.swift) · [Adaptation de Spacewalk](Sources/ProjectHop/DockSwipe.swift) · [Test entre deux Spaces](Tests/cross-space.sh)

## Ce que fait le modèle de langage local

Le LLM sert à **proposer des libellés lisibles** pour le sélecteur et sa recherche. L’identification, l’affectation aux projets et le basculement restent pilotés par les identifiants macOS et les choix de l’utilisateur.

1. Pour chaque fenêtre candidate, ProjectHop transmet au modèle **un numéro temporaire, le nom de l’app et le titre de la fenêtre**, limité à 200 caractères. Si WindowServer ne fournit pas de titre, l’app essaie de lire `AXTitle` via Accessibility. Les titres trop génériques, comme « Nouvel onglet », sont écartés de la requête.
2. `SystemLanguageModel.default` exécute l’inférence **sur le Mac**. ProjectHop traite les fenêtres par lots de six et utilise `@Generable` pour recevoir un numéro et un libellé structuré. L’app valide le numéro et n’accepte que des libellés d’une ligne, de 40 caractères maximum.
3. Avant l’enregistrement, ProjectHop vérifie que la fenêtre est toujours présente et que son libellé n’a pas été modifié entre-temps. Si le modèle est indisponible ou qu’aucune proposition valide n’est renvoyée, le nom de l’app sert de libellé, avec un numéro si nécessaire.

[Nommage local et données transmises](Sources/ProjectHop/LocalWindowNames.swift) · [Validation et stockage](Sources/ProjectHop/WindowNames.swift) · [Modèle sur l’appareil, documentation Apple](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

### Consulter l’inventaire en ligne de commande

Le binaire de la version standard installée accepte les commandes suivantes. `fenetres` renvoie du JSON avec l’identifiant, l’app, le titre, le nom personnalisé, les Spaces et les états plein écran et minimisé. Utilise l’identifiant affiché dans le champ `id` pour `renommer`.

~~~sh
projecthop=/Applications/ProjectHop.app/Contents/MacOS/ProjectHop
"$projecthop" fenetres
"$projecthop" renommer "<id>" "Nom de la fenêtre"
"$projecthop" actualiser-noms
~~~

## Compiler depuis les sources

Ouvre `ProjectHop.xcodeproj` dans Xcode avec le SDK macOS 27.2, puis sélectionne le schéma **ProjectHop** ou **ProjectHop Sandbox**. Les deux cibles compilent les mêmes fichiers sous `Sources/` et utilisent la même version dans `Resources/Info.plist`. Le sandbox est activé dans la configuration de la cible Sandbox.

Le minimum de macOS est défini dans `Resources/ProjectHop.xcconfig` et partagé avec `build.sh`.

Pour préparer une mise à jour, compile les deux schémas en configuration **Release** depuis le même commit.

~~~sh
xcodebuild -scheme ProjectHop -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -scheme 'ProjectHop Sandbox' -configuration Release -destination 'generic/platform=macOS' \
    PRODUCT_BUNDLE_IDENTIFIER=fr.groupesespaces.v2.sandbox DEVELOPMENT_TEAM=32P437V988 build
~~~

Pour archiver la variante destinée à TestFlight, sélectionne **ProjectHop Sandbox** et **Product → Archive**. Le schéma reprend l’identifiant et l’équipe de signature de la version déjà envoyée à Apple. La commande de compilation ci-dessus remplace ces réglages uniquement pour le DMG GitHub, qui utilise son propre identifiant.

Le raccourci `./build.sh` reste disponible pour compiler la version standard dans `build/ProjectHop.app`.
