# Create databases and user for Aegis All-in-One
# This file runs ONLY on first database container creation.
#
# NOTE: setup.sh replaces 'pokemap' with your chosen username.
# If you ran setup.sh after the database was already created,
# run dbsetup.sh to create the user manually.

# Create the database user (setup.sh replaces 'pokemap' and password)
CREATE USER IF NOT EXISTS 'pokemap'@'%' IDENTIFIED BY 'ValorRules';
GRANT ALL PRIVILEGES ON *.* TO 'pokemap'@'%' WITH GRANT OPTION;

# Grant specific database privileges for robustness
GRANT ALL PRIVILEGES ON dragonite.* TO 'pokemap'@'%';
GRANT ALL PRIVILEGES ON golbat.* TO 'pokemap'@'%';
GRANT ALL PRIVILEGES ON reactmap.* TO 'pokemap'@'%';
GRANT ALL PRIVILEGES ON koji.* TO 'pokemap'@'%';
GRANT ALL PRIVILEGES ON poracle.* TO 'pokemap'@'%';

# Create all required databases
CREATE DATABASE IF NOT EXISTS `golbat`;
CREATE DATABASE IF NOT EXISTS `dragonite`;
CREATE DATABASE IF NOT EXISTS `koji`;
CREATE DATABASE IF NOT EXISTS `reactmap`;
CREATE DATABASE IF NOT EXISTS `poracle`;

FLUSH PRIVILEGES;
