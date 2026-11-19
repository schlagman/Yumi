# Plan d'implémentation : routines, jauge de contexte, images pour le web

## Vue d'ensemble
Trois fonctionnalités indépendantes, décrites dans `SPEC.md`, `SPEC-routines.md`, `SPEC-context-gauge.md` et `SPEC-web-images.md`. On les construit dans l'ordre routines → context-gauge → web-images, une tranche testable à la fois, avec un commit par tâche une fois les builds et les tests verts.

## Décisions d'architecture
- **Routines = un nouveau module** (`Modules/Routines/`). Il réutilise la mise en page des sessions (`ModuleActivity`, cas `sessions`) au lieu d'en créer une. Ses données se lisent à la demande dans les fichiers de l'app Claude : aucun stockage propre, sauf l'id de la dernière exécution vue (`UserDefaults`).
- **Décodeur `ClaudeAppCard` pur et partagé** dans `Modules/ClaudeCode/ClaudeAppCard.swift`. Il ne lit que les champs listés dans la spec. Le module Routines est son seul utilisateur, car la jauge prend le modèle par le hook (point suivant).
- **Pour la jauge, le modèle arrive par le hook** : le script de hook lit déjà la carte de l'app Claude au `Stop` pour le titre. Il ajoute `host_model` (deux lignes de Python). Le script est réécrit à chaque lancement (`installHookScript`), donc rien n'est à réinstaller et `~/.claude/settings.json` n'est pas touché.
- **Une seule lecture du transcript au `Stop`** : `SessionNote.from` reçoit la fin du transcript et en tire le dernier message *et* les tokens. Pas de seconde lecture.
- **`WebImage` dans `Core/`**, en pur ImageIO. `Core/` est déjà compilé dans la cible de tests, donc pas de nouvelle ligne dans `project.yml`.
- **App Store** : le module Routines n'est enregistré que hors `APPSTORE`, et le bouton « Pour le web » est masqué dans cette build. Le code compile partout.

## Liste des tâches
Le détail de chaque tâche est dans `tasks/todo.md`.

### Phase 1 : Routines
- [x] Tâche 1 : décodeurs purs (carte de l'app Claude, rapport, état d'une exécution) et leurs tests
- [x] Tâche 2 : le module Routines visible dans l'île, avec de vraies données
- [x] Tâche 3 : la remarque d'initiative « la routine X n'a pas fini »
- [ ] Tâche 4 : documenter le format des rapports et proposer l'étape à ajouter aux `SKILL.md`

### Point de contrôle A
- [ ] Builds Debug et App Store sans avertissement, tests verts
- [ ] Les tâches planifiées réelles apparaissent avec le bon état ; un rapport écrit à la main s'affiche en moins de 2 s

### Phase 2 : Jauge de contexte
- [x] Tâche 5 : tokens et pourcentage au `Stop`, ligne « Contexte NN % », suggestion de `/compact` à 80 %

### Point de contrôle B
- [ ] Tests verts ; sur une vraie session, ±2 points de l'indicateur de Claude Code

### Phase 3 : Images pour le web
- [x] Tâche 6 : `WebImage.make` et ses tests
- [ ] Tâche 7 : bouton « Pour le web » dans la zone de dépose

### Point de contrôle C : terminé
- [ ] Tous les critères des trois specs remplis
- [ ] `/ponytail-review` sur le diff, puis `/agent-skills:review`, puis `graphify update .`
- [ ] Push sur `fork` après ton accord

## Risques et parades
| Risque | Impact | Parade |
|---|---|---|
| Le format des fichiers de l'app Claude change (il n'est pas documenté) | Moyen | Décodage tolérant : un champ inattendu fait ignorer la carte, jamais planter ; même limite de 5 Mo que le script de hook |
| Relire des centaines de cartes à chaque `Stop` coûte | Faible | Relecture regroupée sur 5 s, hors du fil principal ; seules les cartes avec `scheduledTaskId` sont gardées |
| Une session 1M en terminal sous 200 000 tokens est rapportée à 200 000 | Faible | Raccourci assumé et commenté. Les sessions de l'app Claude ont le vrai modèle par `host_model` |
| Rapport JSON malveillant ou énorme | Moyen | 64 Ko maximum, lignes tronquées, lien seulement en http(s) et ouvert seulement au clic |
| La cible de tests compile tout `Modules/` | Faible | Le module n'utilise ni vue ni `AppState`, comme les autres modules |

## Questions ouvertes
Aucune. Les specs restent à la racine, puisque tu les as validées telles quelles.
