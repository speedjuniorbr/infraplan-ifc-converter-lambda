import os
import sys
import boto3
import subprocess
import requests

# Para testes locais, podemos permitir que algumas variáveis não existam
# Em produção no Fargate, elas serão obrigatórias.
SOURCE_BUCKET = os.environ.get('SOURCE_BUCKET', 'local-test-bucket')
SOURCE_KEY = os.environ.get('SOURCE_KEY', 'test/sample.ifc')
CONFIG_ID = os.environ.get('CONFIG_ID', 'local-config-id')
TARGET_BUCKET = os.environ.get('TARGET_BUCKET', 'local-target-bucket')
API_ENDPOINT_URL = os.environ.get('API_ENDPOINT_URL')
API_KEY = os.environ.get('API_KEY')
LOCAL_TEST_MODE = os.environ.get('LOCAL_TEST_MODE', 'false').lower() == 'true'


def notify_api(status, model_path=None, error_message=None):
    if LOCAL_TEST_MODE or not API_ENDPOINT_URL or not API_KEY:
        print("INFO: Modo de teste local ou variáveis da API não definidas. Pulando notificação.")
        return

    url = API_ENDPOINT_URL.format(CONFIG_ID)
    headers = {'Content-Type': 'application/json', 'X-API-Key': API_KEY}
    payload = {
        'status': "CONVERSION_" + status,
        'converted_model_path': model_path,
        'error_message': error_message
    }
    try:
        print(f"Notificando API em {url} com payload: {payload}")
        response = requests.patch(url, json=payload, headers=headers, timeout=20)
        response.raise_for_status()
        print(f"API notificada com sucesso. Status: {response.status_code}")
    except requests.exceptions.RequestException as e:
        print(f"ERRO CRÍTICO ao notificar API: {e}", file=sys.stderr)


def main():
    try:
        ifc_filename = os.path.basename(SOURCE_KEY)
        version_hash = os.path.splitext(ifc_filename)[0]

        download_path = f'/app/data/{ifc_filename}'
        converted_path = f'/app/data/{version_hash}.glb'
        target_key = f"converted_models/{CONFIG_ID}/{version_hash}.glb"

        # Em modo de teste local, não baixamos do S3, o arquivo já está montado.
        if not LOCAL_TEST_MODE:
            s3_client = boto3.client('s3')
            print(f"Baixando s3://{SOURCE_BUCKET}/{SOURCE_KEY} para {download_path}...")
            os.makedirs(os.path.dirname(download_path), exist_ok=True)
            s3_client.download_file(SOURCE_BUCKET, SOURCE_KEY, download_path)
            print("Download completo.")
        else:
            print(f"INFO: Modo de teste local. Esperando encontrar o arquivo em {download_path}")
            if not os.path.exists(download_path):
                print(f"ERRO: Arquivo {download_path} não encontrado! Você montou o volume corretamente?", file=sys.stderr)
                sys.exit(1)

        # Executa a conversão
        print(f"Convertendo {download_path} para {converted_path}...")
        command = ['IfcConvert', download_path, converted_path]
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=1800)
        print("Conversão completa.")
        print(f"IfcConvert stdout: {result.stdout}")

        # Em modo de teste local, não fazemos upload. O resultado fica no volume montado.
        if not LOCAL_TEST_MODE:
            print(f"Fazendo upload de {converted_path} para s3://{TARGET_BUCKET}/{target_key}...")
            s3_client.upload_file(converted_path, TARGET_BUCKET, target_key)
            print("Upload completo.")
            notify_api("SUCCESS", model_path=target_key)
        else:
            print(f"INFO: Modo de teste local. O arquivo convertido está em {converted_path}")
            print("Processo concluído com sucesso!")

    except subprocess.TimeoutExpired:
        error_msg = f"IfcConvert demorou mais que o tempo limite para converter o arquivo."
        print(error_msg, file=sys.stderr)
        if not LOCAL_TEST_MODE: notify_api("FAILED", error_message=error_msg)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        error_msg = f"O processo IfcConvert falhou. Stderr: {e.stderr}"
        print(error_msg, file=sys.stderr)
        if not LOCAL_TEST_MODE: notify_api("FAILED", error_message=e.stderr)
        sys.exit(1)
    except Exception as e:
        error_msg = f"ERRO inesperado durante o processamento: {str(e)}"
        print(error_msg, file=sys.stderr)
        if not LOCAL_TEST_MODE: notify_api("FAILED", error_message=error_msg)
        sys.exit(1)

if __name__ == "__main__":
    main()