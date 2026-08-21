Créée par DOREY Oriane, dernière modification par MAKDECHE Nassim (EXT) il y a 6 minutes
DORA – Gestion des vulnérabilités
Définition et calcul des KPI de couverture SAST / SCA / DAST (GV.4, GV.5, GV.6)
1. Objet de la page
Cette page définit de façon formelle et détaillée :

L’assiette de calcul (dénominateur) pour chaque KPI :
GV.4 : DAST (applications Web DORA)
GV.5 : SCA (applications DORA développées en interne – Specific Dev)
GV.6 : SAST (applications DORA développées en interne – Specific Dev)
La définition de la valeur du KPI (numérateur) : quelles preuves de scan sont prises en compte, via quels outils, et selon quels critères (fréquence, qualité du scan).
La formule de calcul et les règles de gestion (cas particuliers, exclusions, qualité de données).
2. Périmètre DORA & principes généraux
2.1. Périmètre fonctionnel
Les indicateurs couvrent :

Les applications relevant du périmètre DORA
marquage DORA dans REFA : 1 DORA Groupe Coeur, 2 DORA Groupe Satellite, 3 DORA Groupe Socle Technique
Les développements internes
marquage "Specific Dev" ou "Software Package"? dans REFA pour SAST/SCA. 
Les applications Web
présence d'une URL VENAFI associée au CIA pour DAST.
2.2. Référentiels sources
Les informations utilisées pour l’assiette et la valeur sont issues exclusivement des briques suivantes :

REFA (Référentiel des Applications BPCE) :
codes CIA, nature de développement, statut DORA, Statut
Venafi : URLs  et codes CIA
Qualys + DSO : résultats de scans DAST.
Xray / Checkmarx SCA : résultats de scans SCA.
Checkmarx SAST : résultats de scans SAST.
3. KPI GV.4 – Taux d’applications Web DORA scannées automatiquement et mensuellement trimestriellement (DAST)
3.1. Assiette de calcul (dénominateur)
Objectif : Identifier l’ensemble des URLs Web DORA qui doivent être couvertes par une analyse de type DAST.

3.1.1. Source de l’assiette
REFA :
Champ DORA (indique si l’application relève du périmètre DORA).
Champ code CIA (identifiant de l’application).
API VENAFI :
Extraction des URLs  associés aux codes CIA.
3.1.2. Règles de construction de l’assiette
Sélection des applications DORA dans REFA
Dans REFA, sélectionner les applications pour lesquelles :
champ Regulatory DORA dans REFA : 1 DORA Groupe Coeur, 2 DORA Groupe Satellite, 3 DORA Groupe Socle Technique
champ Nature = Specific Dev
Récupération des codes CIA
Pour chaque application DORA, récupérer le code CIA dans REFA.
Interrogation de l’API Venafi
Pour chaque code CIA issu de REFA, interroger Venafi pour :
en déduire les URLs 
Filtrage et normalisation
Normalisation des URLs (schéma, host, port, path si nécessaire).
Deduplication des URLs.
Assiette GV.4 = Nombre total d’URLs Web uniques associées à des applications DORA REFA

3.2. Valeur du KPI (numérateur)
Objectif : Compter les URLs pour lesquelles un scan DAST automatique mensuel trimestriel est effectivement réalisé.

3.2.1. Sources de données de valeur
Portail DSO alimenté en amont par Qualys:
Logs des jobs DAST (statut, URL cible, date).
3.2.2. Critères de prise en compte dans la valeur
Une URL de l’assiette est considérée comme “couvert DAST” pour un mois M/trimestre T si :

Au moins un scan DAST a été exécuté sur cette URL sur la période de temps de référence (trimestriel),
ET
Le scan est terminé sans erreur bloquante (TODO besoin de faire développer la récupération du statut du scan depuis Qualys côté DSO360)
ET
L’URL est clairement présente dans le rapport ou les paramètres du scan.
Valeur GV.4 = Nombre d’URLs de l’assiette (REFA+Venafi) ayant au moins un scan DAST valide sur la période de référence.

3.3. Formule de calcul GV.4
GV.4= Nombre d’URLs de l’assiette (REFA+Venafi) ayant au moins un scan DAST valide sur la période de référence / Nombre total d’URLs Web uniques associées à des applications DORA REFA ×100
4. KPI GV.5 – Taux d’applications DORA développées en interne dont les dépendances sont scannées automatiquement (SCA – hebdomadaire)
4.1. Assiette de calcul (dénominateur)
Objectif : Identifier toutes les applications DORA développées en interne devant être couvertes par un scan SCA.

4.1.1. Source de l’assiette
REFA :
champ Regulatory DORA dans REFA : 1 DORA Groupe Coeur, 2 DORA Groupe Satellite, 3 DORA Groupe Socle Technique
Attribut "Nature"  =  Specific Dev
Code CIA.
4.1.2. Règles de construction de l’assiette
Sélection dans REFA :
Champ Regulatory DORA dans REFA : 1 DORA Groupe Coeur, 2 DORA Groupe Satellite, 3 DORA Groupe Socle Technique
Champ « Nature» = Specific Dev.
Attribut "Status" = "Deployed" 
Agrégation :
Agrégation par code CIA 
Assiette GV.5 = Nombre total d’applications DORA dans REFA dont la Nature de DEV = Specific Dev.

4.2. Valeur du KPI (numérateur)
Objectif : Compter les applications pour lesquelles les dépendances / librairies sont scannées automatiquement chaque semaine.

4.2.1. Sources de données de valeur
Xray : rapports de scans dans DSO360
Checkmarx SCA :
conventions de nommage dans Checkmarx SCA 
Project Name = <CIA>-<nom-module-dans-repo>.folder-<branche> l'attribut folder est utilisé uniquement dans le cas d'un mono-repo (présence du code front et back dans le même repo)
Team = /CxServer/SP/<ENTITE>/<CIA>
4.2.2. Critères de prise en compte dans la valeur
Une application “Specific Dev” de REFA est considérée comme couvert SCA si :

Un de ses modules a été scanné dans Checkmarx SCA ou Xray
ET
Au moins un scan SCA (Xray ou Checkmarx SCA) a été exécuté pour ce module dans les 7 derniers jours


Points de gouvernance :

Le code CIA REFA doit être renseigné systématiquement dans les projets Checkmarx SCA. La mise en conformité du nom du projet Checkmarx SCA est à la main de l'équipe de développement de l'application. L'équipe de développement doit s'assurer de l'utilisation du champ Team dédié au CIA du projet scanné. 
Exemples de mapping REFA ↔ outils :

Code CIA REFA <-> Checkmarx SCA 
Project Name Checkmarx SCA = CIA-moduleBitubucket-branch  exemple : NXCWJ-PYTHON-TEST-SCA-master. En cas de mono repo multi technologie CIA-module-bitbucket.folder-branch
Team name Checkmarx SCA = /CxServer/SP/<ENTITE>/<CIA> exemple : /CxServer/SP/BPCE-IT/NXCWJ
Valeur GV.5 = Nombre d’applications DORA "Specific Dev" (issues de REFA) avec au moins un scan SCA valide (Xray ou Checkmarx SCA) sur les 7 derniers jours.

4.3. Formule de calcul GV.5
GV.5=Nombre d’applications DORA "Specific Dev" scannées SCA (hebdo) / Nombre total d’applications DORA "Specific Dev" dans REFA×100
5. KPI GV.6 – Taux d’applications DORA développées en interne dont au moins une partie du code source est scannée automatiquement (SAST)
5.1. Assiette de calcul (dénominateur)
Objectif : Cibler les mêmes applications internes DORA que pour GV.5, afin d’avoir une cohérence SAST/SCA.

5.1.1. Source de l’assiette
REFA :
champ Regulatory DORA dans REFA : 1 DORA Groupe Coeur, 2 DORA Groupe Satellite, 3 DORA Groupe Socle Technique
Attribut "Nature"  =  Specific Dev
Code CIA.
Assiette GV.6 = Nombre total d’applications DORA "Specific Dev" recensées dans REFA (même périmètre que GV.5).

5.2. Valeur du KPI (numérateur)
Objectif : Compter les applications pour lesquelles au moins une partie du code source est scannée automatiquement en SAST.

5.2.1. Source de données de valeur
Checkmarx SAST :
Projets SAST configurés.
Rapports de scans (branches, pipelines).
5.2.2. Critères de prise en compte dans la valeur
Une application DORA "Specific Dev" de REFA est considérée comme couvert SAST si :

Au moins un de ses modules est mappé à au moins un projet Checkmarx SAST (via code CIA REFA, Project Name ou Team CxSAST),
ET
Au moins un scan SAST a été exécuté de manière automatique
Points de gouvernance :

Le code CIA REFA doit être renseigné systématiquement dans les projets Checkmarx SAST. La mise en conformité du nom du projet Checkmarx SAST est à la main de l'équipe de développement de l'application. L'équipe de développement doit s'assurer de l'utilisation du champ Team dédié au CIA du projet scanné. 
Valeur GV.6 = Nombre d’applications DORA "Specific Dev" (issues de REFA) avec au moins un projet Checkmarx SAST actif et un scan SAST valide sur la période de reporting.

5.3. Formule de calcul GV.6
GV.6=Nombre d’applications DORA "Specific Dev" scannées SAST Nombre total d’applications DORA "Specific Dev" dans REFA×100
6. Résumé des assiettes & valeurs – Vue tabulaire
GV.4	DAST	URLs Web uniques associées aux codes CIA d’applications DORA (REFA + Venafi)	URLs ayant au moins un scan DAST valide sur le mois	REFA + Venafi (assiette), Qualys via DSO360 (valeur)
GV.5	SCA	Applications DORA dans REFA avec Nature de DEV = Specific Dev	Applications avec au moins un scan SCA valide sur 7 jours (Xray ou Checkmarx SCA)	REFA (assiette), Xray via DSO360, Checkmarx SCA (valeur)
GV.6	SAST	Applications DORA dans REFA avec Nature de DEV = Specific Dev	Applications avec au moins un projet Checkmarx SAST actif et un scan valide	REFA (assiette), Checkmarx SAST (valeur)


7. Modalités de reporting et intégration dans les dashboards
Fréquence de récupération des données et calcul
GV.4  GV.5 GV.6 :  journalier
Alimentation
Extraction REFA (DORA + Nature de DEV + CIA).
Jointure avec Venafi, Qualys, DSO360, Xray, Checkmarx SCA/SAST.
Restitution
Dashboard Sécurité Applicative avec :
Vue par KPI,
Vue par application (CIA REFA),
Liste des applications non couvertes et des actions de remédiation.
Date de dernier scan pour chaque CIA
