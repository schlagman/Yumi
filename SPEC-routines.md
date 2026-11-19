# Spec : `routines`

## Objectif
Les tâches planifiées de l'app Claude tournent sans témoin, et on ne sait pas si elles ont livré. Yumi montre, pour chaque tâche, sa dernière exécution, son état et ce qu'elle a produit, et attire l'attention sur une exécution qui n'a pas fini, qui a échoué ou qui attend un clic.

## Sources (lecture seule)

**1. Fichiers de session de l'app Claude** : `~/Library/Application Support/Claude/claude-code-sessions/*/*/*.json`. Ce format n'est pas documenté : tout ce qui est inattendu fait ignorer le fichier, et les fichiers de plus de 5 Mo sont sautés (même règle que le script de hook). Champs lus, et rien d'autre :

| Champ | Type | Sert à |
|---|---|---|
| `sessionId` | `local_…` | ouvrir l'exécution dans l'app Claude (lien `claude://claude.ai/epitaxy/<id>`, déjà utilisé) |
| `scheduledTaskId` | texte | nom du dossier de la tâche dans `~/.claude/scheduled-tasks/` ; sans ce champ, le fichier est ignoré |
| `createdAt`, `lastActivityAt` | millisecondes | dates de l'exécution |
| `completedTurns` | entier ou absent | ≥ 1 : l'exécution a terminé au moins un tour |
| `postTurnSummary.status_detail` | texte ou absent | résumé de la fin de tour |
| `postTurnSummary.needs_action` | booléen ou absent | l'exécution attend quelque chose de toi |
| `model` | texte | réutilisé par `context-gauge` (`[1m]`) |

Le décodeur pur `ClaudeAppCard` vit dans `Modules/ClaudeCode/ClaudeAppCard.swift` : données → carte, ou nil.

**2. Rapports déposés par les routines** : `<dossier de support de Yumi>/Reports/<scheduledTaskId>.json` (le dossier suit `YUMI_SUPPORT_DIR`). Format :
```json
{ "title": "Leads de la semaine", "status": "ok", "lines": ["12 leads", "3 à rappeler"], "link": "https://…", "at": "2026-11-19T09:02:00Z" }
```
- `status` vaut `ok`, `warn` ou `fail`. `lines` : 3 lignes au plus, 120 caractères chacune ; au-delà, c'est tronqué. `link` et `at` sont facultatifs. Fichier de plus de 64 Ko ou JSON invalide : ignoré.
- `link` n'est gardé que s'il commence par `http://` ou `https://`, et il ne s'ouvre qu'au clic.
- Un rapport dont le nom ne correspond à aucune tâche a sa propre ligne : un script peut en déposer un aussi.

**3. État en direct** : par `receive(_:sessions:)`, une session en cours dont `origin.hostSessionID` est celui d'une exécution de routine et qui attend une approbation ou une réponse.

## Comportement

**État de la dernière exécution de chaque tâche**, du plus fort au plus faible :
1. Attend un clic : session en direct en attente, ou `needs_action`. État de ligne `waiting`.
2. Rapport `fail` : `failure`. Rapport `warn` : `waiting`.
3. Aucun tour terminé et aucune activité depuis 30 min : « pas finie », `failure`.
4. Aucun tour terminé, activité récente : « en cours », `busy`.
5. Sinon « terminée », `success`.

**Une ligne par tâche** (`ModuleRow`), les plus récentes d'abord :
- titre : `title` du rapport s'il existe, sinon le nom du dossier de la tâche avec des espaces à la place des tirets ;
- détail : la première ligne du rapport, sinon `status_detail` ;
- `details` : toutes les lignes du rapport ;
- date : `lastActivityAt`, ou `at` du rapport s'il est plus récent ;
- action : ouvrir l'exécution dans l'app Claude, ou le lien du rapport s'il n'y a pas d'exécution.

**Le module** : id `routines`, nom « Routines », onglet Travail. Il n'est pas ajouté aux profils du premier lancement ; une mise à jour l'ajoute une fois à la sélection existante (`ModuleSelection.welcome`). Il reprend la mise en page des sessions Claude Code (`ModuleActivity`, cas `sessions`). Statut : « 3 routines », ou « 1 à voir ».

**Attention** : `needsAttention` est vrai si une exécution des 12 dernières heures est en état 1, 2 ou 3 et que tu n'as pas encore ouvert le module depuis. L'id de l'exécution vue est gardé dans `UserDefaults`.

**Initiative** : nouvelle occasion `routine(name:failed:)`. « La routine X n'a pas fini » ou « La routine X a un souci », avec le bouton « Ouvrir » (`RemarkAction.openSession`). Elle suit les règles existantes (20 min entre deux remarques, silence en Focus, Ne pas déranger, partage d'écran, sujet ignoré 3 fois). Une exécution donnée n'en déclenche qu'une.

**Mise à jour, sans minuterie** :
- au démarrage et au réveil du Mac ;
- sur un `Stop`, un `SessionEnd` ou une demande de permission d'une session de l'app Claude (relecture regroupée sur 5 s) ;
- quand le dossier `Reports/` change (`DispatchSource`).

**Exclusions** :
- Build App Store : le module n'existe pas (`#if !APPSTORE`), car les fichiers de l'app Claude sont hors du bac à sable.
- `YUMI_STUDIO=1` : aucun module ne démarre en mode tournage (`LaunchPlan`), donc rien n'est lu.

**Côté routines (hors dépôt)** : une étape finale dans chaque `SKILL.md` de `~/.claude/scheduled-tasks/`, qui écrit le rapport. On la propose fichier par fichier, diff à l'appui, après ton accord. Le format est documenté dans `docs/architecture.md`.

## Hors périmètre
- Les routines cloud : elles tournent sur les serveurs d'Anthropic et ne laissent rien sur le Mac.
- Prévenir qu'une routine aurait dû tourner : il faudrait lire la planification.
- Écrire dans les fichiers de l'app Claude ou relancer une routine depuis Yumi.

## Critères de réussite
- Au lancement, chaque tâche planifiée qui a déjà tourné a une ligne avec le bon état.
- Une tâche lancée à la main passe par « en cours » puis « terminée » sans redémarrer Yumi. Si elle demande une permission, elle passe par « attend ton clic ».
- Écrire `Reports/<id>.json` change sa ligne en moins de 2 s ; un fichier invalide ne change rien et ne fait pas planter Yumi.
- Un lien de rapport en `file:` ou en `javascript:` n'est jamais ouvert.
- Les builds Debug et App Store passent sans avertissement ; le module est absent de la version App Store.

## Tests (`Yumi/Tests/Routines/`)
- `ClaudeAppCard` : une carte complète ; une sans `scheduledTaskId` ; une sans `completedTurns` ; un `postTurnSummary` absent ou mal formé ; un JSON invalide.
- Le choix de la dernière exécution par tâche, et l'état calculé dans les 5 cas, avec une horloge fixe.
- `RoutineReport` : rapport valide ; lignes et texte trop longs (tronqués) ; lien `file:` ou `javascript:` (retiré) ; statut inconnu (rapport ignoré).
