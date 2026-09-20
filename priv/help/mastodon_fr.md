# Utiliser une application Mastodon

Ici vous pouvez lire et écrire depuis une application conçue pour Mastodon :
Ivory, Tusky, Ice Cubes, Mona, Elk et les autres. Sur votre téléphone, vous
n'avez rien à installer d'autre que l'application elle-même, et vous gardez
votre compte habituel : l'application s'y connecte, comme toute autre
application que vous reliez.

Cette fonction est désactivée jusqu'à ce que vous l'activiez vous-même.

## Comment l'activer

Ouvrez **Paramètres → Applications et accès à l'API** et activez *Autoriser les
applications compatibles Mastodon*. Tant que vous ne le faites pas, une
application peut mener la connexion à son terme puis se voir refuser chacune de
ses requêtes suivantes, ce qui ressemble à une application cassée plutôt qu'à un
interrupteur que vous n'avez pas encore actionné.

La désactivation prend effet immédiatement, y compris pour les applications
depuis lesquelles vous vous êtes déjà connecté. Dans aucun des deux cas rien ne
change sur votre profil.

## L'adresse à saisir

Quand l'application vous demande sur quel serveur vous êtes, saisissez :

```
{{host}}
```

Rien d'autre. N'ajoutez ni `https://`, ni chemin, ni `@`. Votre compte est alors
`@votrenomdutilisateur@{{host}}` : c'est l'adresse à donner à qui veut s'abonner
à vous depuis un autre serveur.

L'application ouvrira ici une page du navigateur, vous demandera de vous
connecter si ce n'est pas déjà fait et vous montrera exactement ce qu'elle
compte faire. Approuvez-la et le navigateur vous rendra à l'application.

## Écrire en tant que page

Si vous faites partie de l'équipe d'une page d'organisation, l'écran
d'approbation vous propose cette page comme seconde identité. Choisissez-la et
tout ce que l'application publie sera de la page, non de vous, exactement comme
lorsque vous passez à la page sur le site. Qui s'est connecté reste enregistré
en coulisses, de sorte que l'équipe peut toujours savoir qui a écrit quoi.

Une application reliée en tant que page ne peut bloquer personne : le blocage
est une affaire entre deux personnes, et une page n'est pas une personne.

## Ce qui fonctionne

* Votre fil, le fil public de cette installation et les fils des hashtags
* Écrire, modifier et supprimer des publications, photos comprises
* J'aime, partages, marque-pages et réponses, avec les mêmes compteurs que sur
  le site
* Les notifications, y compris les notifications push quand l'application est
  fermée
* S'abonner, se désabonner, mettre en sourdine et bloquer : membres, pages et
  comptes sur d'autres serveurs
* Chercher des personnes, des publications et des sujets
* Vos listes d'éléments enregistrés et aimés, vos abonnés et vos abonnements

## Ce qui est différent ici

vutuv n'est pas un serveur Mastodon, donc certaines choses qu'une application
propose ne feront pas ce que vous attendez :

* **Les publications sont publiques.** Le sélecteur d'audience de
  l'application n'a pas d'équivalent ici : qui peut lire une publication, vous
  le restreignez sur le site, pas dans l'application.
* **Pas de sondages, pas d'émojis personnalisés, pas de publications
  programmées.** Une application qui les propose recevra une réponse vide.
* **Les messages directs ne sont pas les messages de Mastodon.** Les messages de
  vutuv sont une chose à part et restent sur le site.
* **Les demandes d'abonnement n'existent pas.** Ici un abonnement prend effet
  aussitôt.

## Si quelque chose ne fonctionne pas

Vérifiez d'abord l'interrupteur, puis l'adresse : ces deux points expliquent
presque tous les problèmes. Si une application s'était connectée il y a des mois
et a cessé de fonctionner, déconnectez-la depuis **Paramètres → Applications et
accès à l'API → Applications connectées** et connectez-vous de nouveau.
