# 진단 회차의 Call Tree 와 트레이스 화면을 찍는 브라우저 자동화다(lc-infra #106).
# 공식 이미지의 판을 고정한다. 판을 올리면 capture.py 의 선택자(라디오 버튼의 id, 버튼 이름)가 그대로 맞는지 다시 찍어 본다.
FROM mcr.microsoft.com/playwright/python:v1.49.1-noble
RUN pip install --no-cache-dir playwright==1.49.1 pillow==11.0.0
COPY capture.py /capture.py
ENTRYPOINT ["python", "/capture.py"]
