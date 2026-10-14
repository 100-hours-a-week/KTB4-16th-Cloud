-- AI가 사용하는 데이터베이스에 접속한 뒤 실행합니다. staging은 mulo_ai, dev는 muro_ai입니다.
-- 운영은 기존 AI DB를 사용합니다. 확장은 인스턴스 전체가 아닌 접속한 데이터베이스에 설치됩니다.
CREATE EXTENSION IF NOT EXISTS vector;
