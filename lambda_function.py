import os
import boto3
import subprocess
import requests
from urllib.parse import unquote_plus

# Inicializa o cliente do S3
s3_client = boto3.client('s3')

# Lê as variáveis de ambiente que serão configuradas na Lambda
TARGET_BUCKET = os.environ.get('TARGET_BUCKET')
API_ENDPOINT_URL = os.environ.get('API_ENDPOINT_URL') # Ex: https://api.infraplan.com/api/v1/internal/configurations/{}/conversion-complete
API_KEY = os.environ.get('API_KEY')

def handler(event, context):
    """Função principal que a AWS Lambda irá executar."""
    
    # 1. Extrai informações do arquivo do evento S3
    record = event['Records'][0]
    source_bucket = record['s3']['bucket']['name']
    source_key = unquote_plus(record['s3']['object']['key'])
    
    print(f"Novo evento: arquivo '{source_key}' no bucket '{source_bucket}'.")

    # --- INÍCIO DA LÓGICA CORRIGIDA ---
    # Com a estrutura de pastas <configuration_id>/<version_hash>.extensao,
    # o configuration_id é a primeira parte do caminho.
    try:
        parts = source_key.split('/')
        if len(parts) < 2:
            raise IndexError("Path não contém o formato esperado de pasta/arquivo.")
        
        config_id = parts[0]
        version_filename = parts[1]
        version_hash = os.path.splitext(version_filename)[0]

        print(f"ID da Configuração extraído: {config_id}")
        print(f"Hash da Versão extraído: {version_hash}")

    except IndexError as e:
        print(f"ERRO: Formato de path inválido. Esperado '<configuration_id>/<version_hash>.ifc', mas recebido '{source_key}'. Detalhe: {e}")
        return {'status': 'failed', 'reason': 'Invalid S3 path format'}

    download_path = f'/tmp/{version_filename}'
    converted_path = f'/tmp/{version_hash}.glb'
    # Vamos salvar o arquivo convertido em uma pasta 'converted_models' seguindo a mesma lógica
    target_key = f"converted_models/{config_id}/{version_hash}.glb"
    # --- FIM DA LÓGICA CORRIGIDA ---

    try:
        # 2. Baixa o arquivo .ifc do S3
        print(f"Baixando s3://{source_bucket}/{source_key} para {download_path}...")
        s3_client.download_file(source_bucket, source_key, download_path)
        print("Download completo.")

        # 3. Executa a ferramenta de conversão IfcConvert
        print(f"Convertendo {download_path} para {converted_path}...")
        subprocess.run(['IfcConvert', download_path, converted_path], check=True, capture_output=True, text=True)
        print("Conversão completa.")

        # 4. Faz o upload do arquivo .glb resultante para o bucket de destino
        print(f"Fazendo upload de {converted_path} para s3://{TARGET_BUCKET}/{target_key}...")
        s3_client.upload_file(converted_path, TARGET_BUCKET, target_key)
        print("Upload completo.")

        # 5. Notifica nossa API que a conversão foi um sucesso
        notify_api(config_id, target_key, "SUCCESS")

    except subprocess.CalledProcessError as e:
        print(f"ERRO CRÍTICO: O processo IfcConvert falhou.")
        print(f"Stderr: {e.stderr}")
        notify_api(config_id, None, "FAILED", f"IfcConvert error: {e.stderr}")
        return {'status': 'failed'}
    except Exception as e:
        print(f"ERRO inesperado durante o processamento: {e}")
        notify_api(config_id, None, "FAILED", str(e))
        return {'status': 'failed'}

    print("Processo concluído com sucesso!")
    return {'status': 'success'}

def notify_api(config_id, model_path, status, error_message=None):
    """Envia uma requisição PATCH para a API interna para atualizar o status."""
    
    url = API_ENDPOINT_URL.format(config_id)
    headers = {
        'Content-Type': 'application/json',
        'X-API-Key': API_KEY
    }
    payload = {
        'converted_model_path': model_path,
        'status': "CONVERSION_" + status,
        'error_message': error_message
    }
    
    try:
        print(f"Notificando API em {url} com payload: {payload}")
        response = requests.patch(url, json=payload, headers=headers, timeout=10)
        response.raise_for_status()
        print(f"API respondeu com status: {response.status_code}")
    except requests.exceptions.RequestException as e:
        print(f"ERRO CRÍTICO ao notificar API: {e}")