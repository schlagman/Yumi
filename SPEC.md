# Carte des fonctionnalités : routines, contexte, images pour le web

Source : le plan approuvé du 19 novembre 2026 (idées n° 1, 2, 3 et 4). Trois fonctionnalités qu'on peut tester séparément ; aucune ne dépend d'une autre.

| Id | Rôle | Dépend de |
|---|---|---|
| `routines` | Suivre les tâches planifiées de Claude (dernière exécution, état, résumé) et afficher les rapports qu'elles déposent | — |
| `context-gauge` | Montrer le remplissage du contexte de chaque session Claude Code et proposer `/compact` à 80 % | — |
| `web-images` | Préparer pour le web une image déposée sur Yumi | — |

Ordre de construction : `routines`, puis `context-gauge`, puis `web-images`. Les trois touchent `Island/IslandActivities.swift`, donc un commit par fonctionnalité, l'une après l'autre.

`routines` et `context-gauge` lisent les mêmes fichiers de session de l'app Claude. Le décodeur `ClaudeAppCard` est écrit avec `routines`, puis réutilisé.

Specs : [SPEC-routines.md](SPEC-routines.md), [SPEC-context-gauge.md](SPEC-context-gauge.md), [SPEC-web-images.md](SPEC-web-images.md).

## Communs aux trois

### Commandes
```
cd Yumi && xcodegen && xcodebuild -scheme Yumi -configuration Debug build
cd Yumi && xcodebuild -scheme Yumi -configuration Debug test CODE_SIGNING_ALLOWED=NO
cd Yumi && xcodebuild -scheme YumiAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
Essai : `YUMI_SUPPORT_DIR=/tmp/yumi-dev YUMI_TRACE_MODULES=1` sur la build Debug ; `YUMI_STUDIO=1` pour vérifier que rien de personnel n'apparaît.

### Structure
- `Yumi/Sources/App/Modules/<Module>/` : le module et ses fonctions pures (aucune vue, ni `AppState`, ni son).
- `Yumi/Sources/App/Island/` : les vues.
- `Yumi/Tests/<Partie>/` : tests Swift Testing. Chaque fichier testé est listé dans la cible `YumiTests` de `Yumi/project.yml` et ne dépend de rien d'autre dans l'app.

### Style
Le style du dépôt : fonctions pures `static` qui reçoivent des données et rendent une valeur, une ligne de commentaire pour le pourquoi, textes visibles en français via `loc()`.
```swift
/// The Claude app opens one of its sessions from a link: that very session, not only the app.
/// Nil unless the session carries an identifier of the exact shape the app gives.
static func deepLink(for origin: SessionOrigin?) -> URL? {
    guard let id = origin?.hostSessionID, id.wholeMatch(of: /local_[0-9a-f-]{36}/) != nil else { return nil }
    return URL(string: "claude://claude.ai/epitaxy/\(id)")
}
```

### Tests
Fonctions pures testées sur des données factices écrites dans le test : pas de vraie session, pas de vrai fichier de l'utilisateur. Pas de test d'interface.

### Limites
- **Toujours** : build Debug et App Store sans avertissement avant chaque commit ; tests verts ; push sur `fork` seulement.
- **Avant de le faire, demander** : toute modification de `~/.claude/` (les `SKILL.md` des routines) ; toute nouvelle permission macOS ou tout nouvel entitlement.
- **Jamais** : de réseau ; de secret ; écrire dans les fichiers de l'app Claude ; lire autre chose que les champs nommés dans les specs ; de nom de client ou de donnée personnelle dans le code, les tests ou les commits (dépôt public).
