# Schéma ALERTE CAMPUS

La migration `migrations/20261111000100_initial_game_schema.sql` définit les huit
entités du MCD. Elle est une proposition à relire : elle n'a pas été appliquée à
la base distante. Aucun jeu de démonstration n'est fourni, car le contenu des
phases, énigmes et indices dépend encore du scénario. Des données fictives
risqueraient de suggérer des règles de validation incorrectes.

## Relations

| Parent | Enfant | Cardinalité |
| --- | --- | --- |
| `utilisateur` | `partie` | 1 vers 0..N en mode Moodle |
| `phase` | `enigme` | 1 vers 0..N |
| `phase` | `partie` | 1 vers 0..N comme phase courante facultative |
| `enigme` | `indice` | 1 vers 0..N |
| `partie` + `enigme` | `progression` | 1 ligne maximum par couple |
| `progression` | `tentative` | 1 vers 0..N |
| `progression` | `utilisation_indice` | 1 vers 0..N |

Les clés étrangères composées garantissent que chaque tentative et chaque
indice utilisé concernent l'énigme de leur progression. Un indice ne peut être
utilisé qu'une fois par partie.

## Identité et reprise

- `moodle` : `utilisateur` contient un couple `(moodle_issuer, moodle_subject)`
  stable et vérifié côté serveur. `auth_user_id` est le lien facultatif vers
  Supabase Auth. Les politiques de lecture personnelles fonctionnent lorsque
  ce lien est renseigné. La future intégration Moodle devra établir ce lien
  ou remplacer ces politiques si elle utilise des JWT tiers directement.
- `test` : une partie sans `utilisateur`, accessible seulement par un endpoint
  serveur après vérification d'un jeton aléatoire de 256 bits. Seule son
  empreinte SHA-256 est stockée ; le jeton brut va dans un cookie `HttpOnly`,
  `Secure`, `SameSite=Lax`, avec `Max-Age` aligné sur
  `jeton_reprise_expire_le`. Les endpoints de mutation vérifient aussi
  l'origine de la requête pour éviter les actions intersites. Ce mode doit
  être activé explicitement en
  développement et désactivé en production par la configuration serveur.
  La base sépare les deux modes, mais ne connaît pas l'environnement de
  déploiement.
- Le cookie de test permet de retrouver une partie après fermeture du
  navigateur tant qu'il et le jeton n'ont pas expiré. La reprise Moodle
  utilisera l'identité authentifiée, y compris entre appareils.
- Le temps restant vaut `max(0, duree_max_secondes - (maintenant -
  commencee_le))`. Le serveur calcule ce temps avec son horloge, sans pause
  pendant l'absence. `duree_max_secondes` est une valeur de configuration du
  scénario copiée dans chaque partie à sa création ; changer le scénario ne
  modifie pas les parties déjà commencées. Dès que la limite est franchie,
  le serveur refuse de nouvelles actions et passe la partie à `expiree`.

## Validation et sécurité

- Les quatre valeurs de `type_validation` sont `texte`, `selection`, `action`
  et `objectifs_interactifs`. `regles_validation` contient une configuration
  privée versionnée. Pour le texte, stocker une empreinte HMAC de la réponse
  normalisée avec un secret serveur. Pour les trois autres types, les règles
  peuvent contenir les identifiants attendus et des conditions de validation.
  Leur format détaillé sera défini avec le moteur de jeu et le scénario.
- Le serveur valide les propositions et les événements d'objectifs. Un simple
  booléen `objectif_atteint` envoyé par le navigateur n'est pas une preuve.
  `etat_objectifs` ne doit contenir que des faits vérifiés côté serveur.
- Les réponses brutes des étudiants ne sont pas enregistrées dans `tentative`.
  Les règles et les indices restent invisibles via l'API directe. Un endpoint
  ne retourne que les champs d'énigme nécessaires à l'écran courant.
- Les clients n'ont aucun droit direct d'écriture. Le serveur traite une
  tentative ou un indice dans une transaction : vérification du propriétaire
  ou du jeton test, contrôle du délai et du statut, validation, insertion de
  l'événement, mise à jour de la progression et du score, puis incrément de
  `partie.version` avec une condition sur l'ancienne version. Les points
  d'une énigme ne sont attribués qu'à sa première résolution. La clé
  `service_role` reste exclusivement côté serveur.
- RLS est activé sur les huit tables. Après liaison Supabase Auth, un étudiant
  authentifié peut lire son profil et ses propres parties et événements.
  Les parties de test sont invisibles via l'API directe. Aucune politique
  d'écriture client n'est créée.

Le schéma seul n'implémente pas le moteur de validation, les transactions ni
le contrôle du mode test : ces garanties dépendent des futurs endpoints
serveur. Le projet Astro devra alors disposer d'un adaptateur serveur.
