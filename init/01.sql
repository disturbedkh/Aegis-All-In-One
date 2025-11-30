# Create databases and user for Aegis All-in-One
# This file runs ONLY on first database container creation.
# 
# NOTE: setup.sh replaces 'dbuser' with your chosen username.
# If you ran setup.sh after the database was already created,
# run dbsetup.sh to create the user manually.

# Create the database user (setup.sh replaces 'dbuser' and password)
CREATE USER IF NOT EXISTS 'dbuser'@'%' IDENTIFIED BY 'SuperSecuredbuserPassword';
GRANT ALL PRIVILEGES ON *.* TO 'dbuser'@'%' WITH GRANT OPTION;

# Create all required databases
CREATE DATABASE IF NOT EXISTS `golbat`;
CREATE DATABASE IF NOT EXISTS `dragonite`;
CREATE DATABASE IF NOT EXISTS `koji`;
CREATE DATABASE IF NOT EXISTS `reactmap`;
CREATE DATABASE IF NOT EXISTS `poracle`;

FLUSH PRIVILEGES;
