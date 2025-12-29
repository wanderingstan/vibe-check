#!/usr/bin/env python3
"""
Passenger WSGI entry point for Hostgator cPanel Python App
"""
import sys
import os

# Add your application directory to the path
sys.path.insert(0, os.path.dirname(__file__))

# Import the Flask app
from app import app as application

# Passenger expects the WSGI application to be named 'application'
