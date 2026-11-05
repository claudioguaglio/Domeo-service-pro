# Suivi Doméo Services Pro

Ce fichier sert de point de reprise. Le mettre à jour après chaque livraison ; ne pas réimplémenter une fonction déjà publiée. Les sauvegardes de données restent hors du dépôt public.

## Dernière livraison validée

- Version fonctionnelle : `011-fiches-intervenantes` (5 novembre 2026).
- Commit du code : `4c188a041a3f7737b5b18d1627b3591b8f7e7ade`. GitHub Pages numéro 18 réussi.
- Migration 011 installée ; tests serveur transactionnels PASS.
- Tests client des fiches, de la reprise, du filtre/export et de la confidentialité : PASS.
- Contrôle réel Carla PASS : fiche Emma retrouvée, filtre de ses missions/bilans, création d'une fiche fictive préparatoire sans compte, modification et relecture des notes multilignes, export filtré téléchargé et relu (211 minutes réalisées, 30 minutes de dépassement).
- Novembre reste à 211 minutes / 119 euros. Une fiche « TEST fiche intervenante — fictive » est conservée sans accès ; ne pas la recréer lors de la reprise. Emma est toujours active. Les bascules d'accès ont été testées uniquement en transactions annulées.
- Page : https://claudioguaglio.github.io/Domeo-service-pro/planning-connecte.html?v=4c188a0

## Version précédente publiée et validée

- Commit : `71b83d604663c56255767227606b8abf36b91747` (5 novembre 2026).
- Migration serveur installée : 010.
- Page : https://claudioguaglio.github.io/Domeo-service-pro/planning-connecte.html?v=71b83d6
- Ancienne application V4.9 conservée séparément ; ses modules ne sont pas tous synchronisés.

## Terminé et vérifié

- Planning connecté, droits responsable/intervenante, commandes reprises sans doublon et contrôle de version.
- Clients modifiables, archivage réversible et tarif historique par mission (006).
- Missions récurrentes (007), bilans mensuels sur toutes les pages (008), export CSV.
- Pointage réel début/fin au serveur, durée calculée, arrêt pendant attente d'un supplément, dépassement visible et exporté (009).
- Correction des oublis par Carla, motif obligatoire et historique avant/après (010).
- Parcours réel Emma début/fin et Carla correction puis rétablissement de la mission fictive à 0 euro : réussis dans le navigateur intégré.
- Novembre de référence : 211 minutes / 119 euros, dont une minute fictive. Deux corrections de contrôle conservées, sept missions et trois clients. Ne pas supprimer ni recréer ces données lors d'une reprise.

## Implémenté — 011

Gestion des fiches intervenantes dans Carla : contact et notes internes, recherche, activation/désactivation des comptes déjà rattachés, filtre de missions et bilans. Ajout de fiches préparatoires sans création automatique de compte ni envoi d'invitation. Préserver les liens des comptes existants.

Fichiers : `011-fiches-intervenantes.sql`, `test-fiches-intervenantes.sql`, interface et tests client mis à jour. Sauvegarde avant migration créée le 5 novembre : 7 missions, 3 clients, 27 commandes et deux corrections de contrôle. Aucune nouvelle invitation ni aucun rattachement de compte n'est inclus dans cette étape.

Le présent journal est actualisé après contrôle réel dans un commit documentaire. Le code de la version 11 reste celui de `4c188a0`. Ne pas redévelopper ces fonctions : la prochaine étape est le rattachement sécurisé des nouveaux comptes, puis les autres modules listés ci-dessous.

## À faire ensuite

- Rattachement sécurisé et invitation des nouvelles intervenantes : accès à valider explicitement, aucune invitation implicite.
- Autres modules V4.9 : règlements, références NeedMe/factures, demandes Airbnb, photos et outils journée.
- Essai sur téléphone physique, capacité avec 10 à 50 comptes distincts, sauvegarde et restauration complète Supabase.

## Règles de reprise

1. Lire ce fichier, comparer la version GitHub et la version serveur aux dernières versions notées.
2. Examiner les modifications locales avant toute synchronisation. Ne pas réinitialiser ni remplacer un dossier de travail existant.
3. Sauvegarder avant migration ; distinguer sauvegarde applicative et sauvegarde complète des comptes/configuration/Storage.
4. Tester uniquement avec des données fictives identifiées ; documenter leur effet sur les bilans.
5. Mettre à jour ce journal et le README dans le même commit que la livraison.
