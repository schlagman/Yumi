# Spec : `context-gauge`

## Objectif
Les longues sessions saturent leur contexte et se compactent au mauvais moment. Yumi affiche le remplissage de chaque session Claude Code et propose `/compact` tant qu'elle est au repos, avant que ce soit trop tard.

## Calcul
- Au `Stop` d'une session, le transcript est déjà lu pour le dernier message : `SessionText.readTail` (64 Ko), appelé depuis `Hooks/HookServer.swift:126`.
- Une fonction pure `SessionText.contextTokens(transcript:) -> Int?` prend la dernière ligne `assistant` qui a un `message.usage` et additionne `input_tokens`, `cache_read_input_tokens` et `cache_creation_input_tokens`.
- Taille de la fenêtre :
  - 1 000 000 tokens si le `model` de la carte de l'app Claude de cette session finit par `[1m]` (décodeur `ClaudeAppCard`, voir `routines`) ;
  - 1 000 000 aussi si le total dépasse déjà 200 000 ;
  - sinon 200 000.
  - Raccourci : une session de terminal en 1M sous 200 000 tokens est rapportée à 200 000. À reprendre si Claude Code transmet un jour le modèle dans ses hooks.
- Le pourcentage est arrondi à l'unité et borné entre 0 et 100.

## Affichage
- Ligne de session (`ModuleRow` du module claude-code) : « Contexte 64 % » parmi les `details`, la ligne qu'on déplie.
- À 80 % ou plus, quand la session est au repos (`Stop`, ni en train de travailler ni en attente), le détail de la ligne devient « Contexte à 85 %, pense à /compact ».
- Pas de nouvelle remarque d'initiative : la ligne suffit.
- Après `/compact` ou `/clear` (`SessionStart` de source `compact` ou `clear`), la jauge s'efface jusqu'au `Stop` suivant : l'ancien chiffre serait faux.

## Hors périmètre
L'état « compacte » pendant la compaction : il faudrait installer le hook PreCompact, donc modifier `~/.claude/settings.json`. À faire plus tard, avec la procédure de sauvegarde, de diff et de confirmation.

## Critères de réussite
- Le pourcentage affiché est à ±2 points de celui de l'indicateur de contexte de Claude Code sur la même session.
- Une session à 85 % au repos montre la suggestion ; si elle travaille, elle ne la montre pas.
- Un transcript illisible, ou sans `usage`, n'affiche rien et ne casse rien.

## Tests (`Yumi/Tests/ClaudeCode/`)
- `contextTokens` :
  - une fin de transcript avec plusieurs lignes `assistant` : c'est la dernière qui compte ;
  - une ligne tronquée au début (lecture de la fin du fichier) ;
  - aucun `usage` ;
  - des champs de cache absents.
- Le pourcentage : 200 000 contre 1M (`[1m]`, puis plus de 200 000) ; les bornes 0 et 100.
