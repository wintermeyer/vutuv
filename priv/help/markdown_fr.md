# Mettre en forme un texte avec Markdown

Partout où vous écrivez plus d'une ligne sur vutuv, nous comprenons le
Markdown : dans les publications et les réponses, dans les messages, dans les
descriptions de votre expérience professionnelle et de votre formation, dans les
offres d'emploi et sur les pages d'organisation. Markdown n'est pas un langage de
programmation, c'est une poignée de caractères qui s'apprennent en cinq minutes :
deux astérisques pour le gras, un tiret pour un élément de liste.

Dans l'éditeur de publications, vous avez rarement besoin d'en taper. Il vous
montre le résultat pendant que vous écrivez : sélectionnez quelques mots et une
petite barre apparaît pour le gras, l'italique, les titres et le reste ; tapez
`/` au début d'une ligne vide pour les titres, les listes, les citations et les
blocs de code. Si vous préférez taper les caractères vous-même, le sélecteur
**Text | Markdown** sous le champ ouvre la vue du code source. Cette page est
écrite pour les deux sortes d'auteurs, et tout ce qu'elle contient est réel :
chaque exemple ci-dessous est rendu exactement comme il apparaîtra dans votre
publication.

## Gras, italique, barré

| Vous écrivez | Vous obtenez |
| --- | --- |
| `**important**` | **important** |
| `*accentué*` | *accentué* |
| `***les deux***` | ***les deux*** |
| `~~supprimé~~` | ~~supprimé~~ |
| `` `un extrait` `` | `un extrait` |

Le tiret bas fait le même travail que l'astérisque : `_accentué_` et
`__important__` fonctionnent aussi. Quand un astérisque doit vraiment être un
astérisque, faites-le précéder d'une barre oblique inverse : `\*ainsi\*` sort
comme \*ainsi\*.

## Paragraphes et retours à la ligne

Une ligne vide commence un nouveau paragraphe. C'est la manière la plus fiable
de donner une forme à un texte.

Un simple retour à la ligne à l'intérieur d'un paragraphe n'est *pas* conservé
dans une **publication** : le texte continue, comme dans un livre. C'est
volontaire, car sinon chaque coupure laissée par un autre programme au moment où
vous avez copié le texte apparaîtrait comme une coupure forcée dans votre
publication. Dans les **messages**, c'est l'inverse : là, chaque nouvelle ligne
va vraiment à la ligne, parce qu'on écrit en lignes courtes dans une
conversation.

## Liens, mentions et hashtags

Une adresse qui commence par `http://` ou `https://` devient un lien d'elle-même.
À l'affichage, nous raccourcissons les adresses très longues, pour qu'elles ne
puissent pas faire exploser une colonne étroite ; en appuyant dessus on arrive
tout de même à la destination complète.

Quand le texte du lien compte, mettez ce texte entre crochets et l'adresse entre
parenthèses juste après :

```markdown
[la liste des membres](https://{{host}}/system/members)
```

[la liste des membres](https://{{host}}/system/members)

Une `@` devant un nom d'utilisateur renvoie à ce profil, à condition que le
membre existe. Un nom que nous ne connaissons pas reste du texte simple, ainsi un
lien ne finit jamais dans le vide. La même syntaxe atteint les personnes
ailleurs dans le Fédiverse si vous indiquez leur serveur : `@nom@serveur.social`
renvoie là-bas.

Un `#` devant un mot renvoie à la page de ce tag, à condition que le tag
appartienne à quelqu'un sur vutuv. Ainsi `#elixir` mène le lecteur aux membres
qui connaissent Elixir.

## Listes

Un tiret et une espace font une puce. Deux espaces de retrait font un
sous-niveau.

```markdown
- Entretiens
- Intégration
  - Première semaine
  - Premier mois
```

- Entretiens
- Intégration
  - Première semaine
  - Premier mois

Les listes numérotées veulent un chiffre et un point :

```markdown
1. Vous publiez l'offre
2. Vous parlez aux personnes
3. Vous faites une proposition
```

1. Vous publiez l'offre
2. Vous parlez aux personnes
3. Vous faites une proposition

Les listes à cases à cocher (`- [ ]`) ne sont pas prises en charge. Elles
sortent pour ce qu'elles sont : des crochets dans le texte.

## Titres

De un à six dièses en début de ligne, puis une espace :

```markdown
## D'où nous sommes partis
### Un détail à ce sujet
```

Dans les publications, les titres sont rendus en gras plutôt qu'à la taille d'un
titre. Une publication est assez courte pour qu'un grand titre l'aplatisse
visuellement. La structure reste tout de même, pour les moteurs de recherche et
pour qui se fait lire la publication à voix haute.

## Citations

Un signe « plus grand que » en début de ligne détache le texte comme citation :

```markdown
> Nous recrutons deux développeurs.
```

> Nous recrutons deux développeurs.

## Ligne horizontale

Trois tirets seuls sur une ligne tracent une ligne :

```markdown
---
```

---

## Code

Les commandes isolées, les noms de fichiers ou les noms de champs vont entre
accents graves simples : `` `mix test` `` devient `mix test`. À l'intérieur de
ces accents, rien d'autre ne se passe, donc un `*` reste un `*`.

Les extraits plus longs vont entre deux lignes de trois accents graves. Écrivez
le langage juste après la première ligne et le bloc reçoit son nom dans le coin
et le code en couleurs :

````markdown
```elixir
# une salutation
IO.puts("Bonjour #{prenom}")
```
````

```elixir
# une salutation
IO.puts("Bonjour #{prenom}")
```

Nous connaissons une quarantaine de langages, dont Elixir, Erlang, Ruby, Python,
PHP, JavaScript, TypeScript, Go, Rust, Java, Kotlin, Swift, C, C++, C#, SQL,
HTML, CSS, YAML, JSON, Bash et Dockerfile. Un langage que nous ne connaissons pas
ne fait pas de dégâts : le bloc reçoit tout de même son étiquette, il ne reçoit
simplement pas les couleurs. Pour que le bloc ne porte aucune étiquette, écrivez
`text` après les accents graves.

Tout cela se passe sur notre serveur. Votre navigateur ne télécharge pas une
ligne de code de plus pour la coloration, et un lecteur qui ne voit jamais un
bloc de code ne paie rien pour l'avoir.

### Indiquer le fichier

Souvent un extrait n'a de sens que lorsqu'on sait de quel fichier il vient.
Écrivez le nom après les deux points :

````markdown
```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```
````

```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```

Si vous préférez la forme longue, écrivez plutôt
`title="app/Providers/AppServiceProvider.php"`. Les deux produisent le même
bloc. La forme longue ne vous sert que lorsque le titre contient une espace.

### Montrer une modification

Le langage `diff` montre ce qui a changé. Les lignes qui commencent par `-`
comptent comme retirées, celles qui commencent par `+` comme ajoutées :

````markdown
```diff
- $port = 4000
+ $port = 4001
```
````

```diff
- $port = 4000
+ $port = 4001
```

Un diff ne dit toutefois rien du langage dans lequel le code modifié est écrit,
et c'est pourquoi il restait autrefois sans couleurs. Indiquez le langage après
les deux points et vous obtenez les deux choses : la modification est mise en
évidence et le code est coloré.

````markdown
```diff:elixir
  def start(_type, _args) do
-   Logger.info("ancien")
+   Logger.info("nouveau")
  end
```
````

```diff:elixir
  def start(_type, _args) do
-   Logger.info("ancien")
+   Logger.info("nouveau")
  end
```

Écrit en entier, cela donne `lang="elixir"`. Un nom de fichier tient tout de
même à côté.

## Tableaux

Les barres verticales séparent les colonnes, la deuxième ligne de tirets sépare
l'en-tête du reste :

```markdown
| Poste | Lieu | Ouvert depuis |
| --- | --- | --- |
| Backend | À distance | mars |
| Design | Hambourg | mai |
```

| Poste | Lieu | Ouvert depuis |
| --- | --- | --- |
| Backend | À distance | mars |
| Design | Hambourg | mai |

Les barres n'ont pas besoin d'être alignées. Un tableau trop large pour l'écran
peut se faire défiler latéralement.

## Notes de bas de page

Une note a deux parties : le repère dans le texte et la note en dessous. Le
numéro entre les deux, c'est vous qui le choisissez, il doit seulement
correspondre.

```markdown
Le chiffre d'affaires a doublé[^1].

[^1]: Mesuré sur le même trimestre l'an dernier.
```

Le chiffre d'affaires a doublé[^1].

[^1]: Mesuré sur le même trimestre l'an dernier.

Les notes se rassemblent à la fin du texte. En appuyant sur un repère on saute à
sa note ; le bouton Retour du navigateur, ou le geste Retour du téléphone, vous
ramène aussitôt là où vous lisiez.

## Images

Les images ne vont que dans les publications, et seulement celles que vous avez
envoyées vous-même. Le chemin est **Ajouter des images** dans l'éditeur, ou
simplement glisser un fichier image dans le texte. Une image qui se trouve au
milieu du texte peut ensuite être placée à gauche, à droite ou au centre :
sélectionnez-la et la petite barre propose les trois alignements. Le texte
s'écoule alors autour d'elle.

Pointer vers l'image de quelqu'un d'autre sur le web n'est pas possible, et
c'est volontaire : sinon chaque affichage de votre publication communiquerait
l'adresse IP de chaque lecteur à un serveur qui n'est pas le nôtre.

## Ce que nous ne rendons pas

Le HTML est montré, pas exécuté. Écrivez `<b>gras</b>` et vos lecteurs verront
`<b>gras</b>`. C'est une décision de sécurité : si nous exécutions le HTML
d'autrui, on pourrait s'en servir pour introduire du code hostile dans la page
d'un autre membre.

Manquent également les listes de tâches à cases à cocher et les vidéos ou les
cartes intégrées. Un lien vers la vidéo rend le même service.

## Quand quelque chose ne fonctionne pas

Écrivez une publication en mentionnant `@vutuv`, ou signalez-le comme
[bug sur GitHub]({{issues}}). vutuv est open source, et les règles de cette page
sont du code dans le dépôt.
