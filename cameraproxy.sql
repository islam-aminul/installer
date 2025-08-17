-- Create database
CREATE DATABASE icamera;

-- Create user
CREATE USER 'icamera'@'localhost' IDENTIFIED BY 'icamera';

-- Grant permissions
GRANT ALL PRIVILEGES ON icamera.* TO 'icamera'@'localhost';

-- Flush privileges
FLUSH PRIVILEGES;

-- Create table
CREATE TABLE icamera.users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    password VARCHAR(255) NOT NULL
);

-- Insert default user
INSERT INTO icamera.users (username, password) VALUES ('admin', 'admin');

-- Create table
CREATE TABLE icamera.cameras (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    ip_address VARCHAR(255) NOT NULL,
    port INT NOT NULL,
    username VARCHAR(255) NOT NULL,
    password VARCHAR(255) NOT NULL
);

-- Insert default camera
INSERT INTO icamera.cameras (name, ip_address, port, username, password) VALUES ('Camera 1', '192.168.1.1', 8080, 'admin', 'admin');

-- Create table
CREATE TABLE icamera.logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp TIMESTAMP NOT NULL,
    level VARCHAR(255) NOT NULL,
    message VARCHAR(255) NOT NULL
);

-- Insert default log
INSERT INTO icamera.logs (timestamp, level, message) VALUES (NOW(), 'INFO', 'iCamera Proxy started');

