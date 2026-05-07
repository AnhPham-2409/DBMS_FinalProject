import mysql.connector
import os

class DBManager:
    def __init__(self):
        # Update these with your real MySQL credentials
        self.config = {
            'host': '127.0.0.1',
            'user': 'root',
            'password': 'your_password',
            'database': 'sports_ticketing_db'
        }

    def get_connection(self):
        return mysql.connector.connect(**self.config)

    def fetch_all(self, query, params=None):
        conn = self.get_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute(query, params or ())
        result = cursor.fetchall()
        cursor.close()
        conn.close()
        return result

    def fetch_one(self, query, params=None):
        conn = self.get_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute(query, params or ())
        result = cursor.fetchone()
        cursor.close()
        conn.close()
        return result

    def execute_sp_booking(self, event_id, seat_id, customer_id, box_office_id, price, reason):
        """Calls the stored procedure for an atomic booking."""
        conn = self.get_connection()
        cursor = conn.cursor()
        try:
            # Arguments match the sp_book_ticket defined in SQL
            args = (event_id, seat_id, customer_id, box_office_id, price, reason, 0, '')
            result_args = cursor.callproc('sp_book_ticket', args)
            conn.commit()
            return True, result_args[7] # Returns p_message from SP
        except Exception as e:
            conn.rollback()
            return False, str(e)
        finally:
            cursor.close()
            conn.close()