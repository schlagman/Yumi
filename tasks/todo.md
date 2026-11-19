# Tâches : routines, jauge de contexte, images pour le web

Commandes (depuis `Yumi/`) :
- build : `xcodegen && xcodebuild -scheme Yumi -configuration Debug build`
- tests : `xcodebuild -scheme Yumi -configuration Debug test CODE_SIGNING_ALLOWED=NO`
- App Store : `xcodebuild -scheme YumiAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO`

## Tâche 1 : décodeurs purs des routines
**Description :**
- `ClaudeAppCard` décode une carte de session de l'app Claude : `sessionId`, `scheduledTaskId`, `createdAt`, `lastActivityAt`, `completedTurns`, `postTurnSummary.status_detail`, `postTurnSummary.needs_action`, `model`.
- `RoutineReport` décode et nettoie un rapport.
- `RoutineRun` garde la dernière exécution par tâche et calcule son état.

**Critères d'acceptation :**
- [x] Une carte sans `scheduledTaskId`, ou un JSON invalide, donne nil sans planter.
- [x] Les 5 états de la spec sont calculés avec une horloge fixe.
- [x] Rapport : lignes coupées à 3 et 120 caractères, lien `file:` ou `javascript:` retiré, statut inconnu → nil.

**Vérification :** tests `Yumi/Tests/Modules/RoutinesTests.swift` verts ; build Debug.
**Dépendances :** aucune.
**Fichiers :** `Modules/ClaudeCode/ClaudeAppCard.swift`, `Modules/Routines/RoutineRun.swift`, `Tests/Modules/RoutinesTests.swift`.
**Taille :** S.

## Tâche 2 : le module Routines dans l'île
**Description :** `RoutinesModule`.
- Données : parcourt les cartes, lit `Reports/` dans le dossier de support (qui suit `YUMI_SUPPORT_DIR`).
- Mise à jour : surveille ce dossier avec `DispatchSource`, se met à jour au réveil et sur `Stop`, `SessionEnd` ou une demande de permission d'une session de l'app Claude (regroupé sur 5 s), et détecte en direct les exécutions en attente.
- Affichage : une ligne par routine ; un clic ouvre l'exécution dans l'app Claude ou ouvre le lien du rapport ; mode studio pris en charge.
- Branchement : enregistré hors `APPSTORE` ; onglet Travail ; profils « bureau » et « code » ; mise en page `sessions` dans l'île.

**Critères d'acceptation :**
- [ ] Au lancement, chaque tâche planifiée déjà exécutée a sa ligne.
- [ ] Un `Reports/<id>.json` écrit à la main change la ligne en moins de 2 s.
- [ ] `needsAttention` ne reste vrai que tant que l'exécution ratée n'a pas été vue.

**Vérification :** build Debug et App Store ; lancement avec `YUMI_SUPPORT_DIR` et `YUMI_TRACE_MODULES=1` ; `YUMI_STUDIO=1` n'affiche que la routine fictive.
**Dépendances :** tâche 1.
**Fichiers :** `Modules/Routines/RoutinesModule.swift`, `App/AppDelegate.swift`, `Modules/ModuleCategory.swift`, `Modules/WorkProfiles.swift`, `Island/IslandActivities.swift`.
**Taille :** M.

## Tâche 3 : remarque d'initiative
**Description :** occasion `routine(name:failed:)` avec sa phrase, son sujet et le bouton « Ouvrir ». Le module la signale une seule fois par exécution, via une fermeture branchée sur `initiative.notice`.

**Critères d'acceptation :**
- [ ] Une exécution pas finie ou en échec donne une remarque, une seule fois.
- [ ] Les refus existants s'appliquent (Focus, Ne pas déranger, 20 min entre deux remarques).

**Vérification :** test dans `Tests/Initiative/` ; build.
**Dépendances :** tâche 2.
**Fichiers :** `Initiative/InitiativeEngine.swift`, `Modules/Routines/RoutinesModule.swift`, `App/AppDelegate.swift`, un test d'initiative.
**Taille :** S.

## Tâche 4 : format des rapports
**Description :**
- Documenter le format dans `docs/architecture.md`.
- Préparer, pour chaque `SKILL.md` de `~/.claude/scheduled-tasks/`, l'étape finale qui écrit le rapport. Montrer le diff de chaque fichier et ne rien écrire sans accord.

**Critères d'acceptation :**
- [ ] Le format est documenté.
- [ ] Les diffs sont proposés ; rien n'est écrit dans `~/.claude/` sans accord.

**Vérification :** relecture.
**Dépendances :** tâche 2.
**Fichiers :** `docs/architecture.md`.
**Taille :** XS.

## Point de contrôle A
- [ ] Builds Debug et App Store sans avertissement, tests verts
- [ ] Vraies tâches planifiées visibles, rapport manuel affiché
- [ ] Commit

## Tâche 5 : jauge de contexte
**Description :**
- Le script de hook transmet `host_model`.
- `SessionNote.from` reçoit la fin du transcript et en tire le dernier message et les tokens (`SessionText.contextTokens`) ; un pourcentage est calculé à partir de la fenêtre.
- Le journal garde ce pourcentage, ajoute « Contexte NN % » aux détails de la ligne, et à 80 % ou plus, session au repos, change le détail en suggestion de `/compact`.

**Critères d'acceptation :**
- [ ] C'est la dernière ligne `assistant` avec un `usage` qui compte ; les champs de cache absents valent 0.
- [ ] La fenêtre est de 1M avec `[1m]` ou au-delà de 200 000 tokens, sinon 200 000 ; le pourcentage est borné entre 0 et 100.
- [ ] La suggestion n'apparaît pas pendant que la session travaille.

**Vérification :** `ClaudeSessionJournalTests` mis à jour et verts ; comparaison avec l'indicateur de Claude Code sur une vraie session.
**Dépendances :** aucune.
**Fichiers :** `Modules/ClaudeCode/ClaudeSessionJournal.swift`, `Hooks/HookServer.swift`, `Modules/ClaudeCode/ClaudeSessions.swift`, `Tests/Modules/ClaudeSessionJournalTests.swift`.
**Taille :** M.

## Point de contrôle B
- [ ] Tests verts, builds sans avertissement, commit

## Tâche 6 : `WebImage.make`
**Description :** avec ImageIO seulement :
- plus grand côté ramené à 2000 px, sans jamais agrandir ; orientation EXIF appliquée ; métadonnées retirées ;
- PNG si l'image a de la transparence, sinon JPEG en qualité 0,82 ;
- l'original est recopié tel quel s'il est déjà plus léger.

**Critères d'acceptation :**
- [ ] Une image de 4000 × 3000 donne 2000 × 1500 en JPEG.
- [ ] Une image transparente reste en PNG avec sa transparence.
- [ ] Une image de 800 px n'est pas agrandie.
- [ ] Des données qui ne sont pas une image donnent nil.

**Vérification :** `Tests/Core/WebImageTests.swift` vert.
**Dépendances :** aucune.
**Fichiers :** `Core/WebImage.swift`, `Tests/Core/WebImageTests.swift`.
**Taille :** S.

## Tâche 7 : bouton « Pour le web »
**Description :**
- `IslandActions.webReady()` écrit `~/Downloads/<nom>-web.<ext>` sous un nom libre, montre le fichier dans le Finder, et joue le son et la pose de réussite habituels.
- Le bouton n'apparaît que pour une image, et pas dans la build App Store.

**Critères d'acceptation :**
- [ ] Une image déposée donne un fichier dans Téléchargements, montré dans le Finder.
- [ ] Un PDF n'affiche pas le bouton.
- [ ] En cas d'échec, Yumi le dit et le fichier déposé reste là.

**Vérification :** build Debug et App Store ; déposer un vrai PNG de 4000 px.
**Dépendances :** tâche 6.
**Fichiers :** `Island/IslandActivities.swift`, `Island/IslandContent.swift`.
**Taille :** S.

## Point de contrôle C : terminé
- [ ] Tous les critères des specs remplis
- [ ] `/ponytail-review`, `/agent-skills:review`, `graphify update .`
- [ ] Push sur `fork` après ton accord
