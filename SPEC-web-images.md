# Spec : `web-images`

## Objectif
Avant de mettre une image sur le site, il faut la redimensionner et la compresser, ce qui se fait aujourd'hui à la main avec `sips`. Désormais, on dépose l'image sur Yumi et on clique sur « Pour le web » : une version légère arrive dans Téléchargements.

## Comportement
- Dans `DropActivity` (`Island/IslandActivities.swift`), un quatrième bouton « Pour le web » (symbole `photo`). Il n'apparaît que si le fichier déposé est une image (`UTType` conforme à `.image`).
- `IslandActions.webReady()` (`Island/IslandContent.swift`), sur le modèle de `summarize()` :
  - appelle la fonction pure `WebImage.make(from: URL) -> (data: Data, ext: String)?` ;
  - écrit `~/Downloads/<nom>-web.<ext>`, avec un suffixe `-2`, `-3`… si le nom est déjà pris ;
  - montre le fichier dans le Finder et joue le son et la pose de réussite habituels ;
  - en cas d'échec, Yumi le dit en une phrase et le fichier déposé reste là.
- `WebImage.make`, avec ImageIO seulement :
  - plus grand côté ramené à 2000 px s'il est plus grand ; jamais agrandi ; orientation EXIF appliquée ;
  - image avec transparence : PNG ; sinon JPEG en qualité 0,82 ;
  - métadonnées retirées (GPS, appareil) ;
  - toujours réencodée, même petite : recopier l'original garderait ses métadonnées (GPS).

## Hors périmètre
- WebP et AVIF : Webflow convertit lui-même dans son panneau d'assets.
- Plusieurs images à la fois : la dépose de Yumi ne prend qu'un fichier aujourd'hui.
- La version App Store : sans droit d'écriture dans Téléchargements, le bouton n'y existe pas (`#if !APPSTORE`).

## Critères de réussite
- Un PNG opaque de 4000 × 3000 donne un JPEG de 2000 × 1500, beaucoup plus léger.
- Un PNG transparent reste un PNG avec sa transparence.
- Une photo de téléphone tournée par EXIF ressort dans le bon sens, sans coordonnées GPS.
- Un PDF ou un fichier texte n'affiche pas le bouton.

## Tests (`Yumi/Tests/Island/`, avec `WebImage.swift` sans dépendance au reste de l'app)
- Image opaque de 4000 × 3000 générée en mémoire : 2000 × 1500 en JPEG.
- Image transparente : PNG, couche alpha conservée.
- Petite image de 800 px : pas agrandie.
- Données qui ne sont pas une image : nil.
