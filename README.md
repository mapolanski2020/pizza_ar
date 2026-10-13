# Monte a Pizza · jogo AR + CRM de fidelidade

Jogo de realidade aumentada para caixas de pizza, com cartão fidelidade na nuvem.
Cada adesivo tem um QR Code único: o primeiro celular que registra ganha 1 ponto e
libera a próxima fase. Quem escanear um adesivo já usado joga só a fase 1.

| Arquivo | O que é |
| --- | --- |
| `index.html` | O jogo (cliente). Abre pelo QR do adesivo: `.../?s=CODIGO` |
| `painel.html` | Painel da pizzaria (CRM): clientes, pontos, provas de compra, resgates, adesivos |
| `supabase/schema.sql` | Banco de dados e regras anti-trapaça (rodar no Supabase) |
| `config.js` | Endereço do Supabase e do jogo |
| `adesivo-arte.png`, `targets.mind` | Arte do adesivo e marcador de AR |
| `models.glb` | Ingredientes 3D (KayKit, de Kay Lousberg, CC0) |

## Rodar com Docker (PostgreSQL no seu computador)

Sobe dois contêineres: **db** (PostgreSQL 16, com os dados num volume) e **app**
(servidor do painel, do jogo, do login e das regras).

1. Instale e abra o **Docker Desktop** (https://www.docker.com/products/docker-desktop).
2. Na pasta do projeto, dê dois cliques em **`iniciar-docker.bat`** (Windows) ou
   **`iniciar-docker.command`** (Mac). Ele descobre o endereço do computador na rede,
   sobe tudo e abre o painel. A primeira vez demora alguns minutos.
3. O **código da equipe** aparece na janela (ou rode `docker compose logs app`).
4. No navegador, aceite o aviso do certificado (*Avançado → Continuar*), vá em
   **Criar acesso** com o código da equipe e gere os adesivos.

Comandos úteis, na pasta do projeto:

| Para | Comando |
| --- | --- |
| Subir | `docker compose up -d --build` |
| Ver o código da equipe | `docker compose logs app` |
| Desligar (mantém os dados) | `docker compose down` |
| Apagar tudo e começar do zero | `docker compose down -v` |
| Abrir o banco no pgAdmin/DBeaver | `localhost:5432`, banco `montepizza`, usuário `pizza`, senha `pizza_local_123` |

Importante: abra o painel pelo endereço da rede (ex.: `https://192.168.0.10:8443/painel.html`),
que é o que o script abre. Os QR Codes impressos apontam para esse endereço, e é por ele
que o celular acessa.

## Rodar sem Docker (banco embutido)

A pasta `local/` tem um servidor que faz o papel da nuvem: banco de dados,
login do painel e as mesmas regras anti-trapaça. Os dados ficam em `local/dados`.

1. Instale o **Node.js** (versão LTS) em https://nodejs.org.
2. Abra a pasta `local` e dê dois cliques em **`iniciar.bat`** (Windows) ou
   **`iniciar.command`** (Mac). Na primeira vez ele instala o que precisa.
3. A janela mostra o **código da equipe** e os endereços. O painel abre sozinho em
   `https://localhost:8443/painel.html`. O navegador avisa que o certificado não é
   confiável: é normal num servidor local, clique em *Avançado → Continuar*.
4. Em **Criar acesso**, use o código da equipe. Depois gere um lote de adesivos.
5. **No celular** (mesmo Wi-Fi do computador): escaneie um adesivo impresso. O QR
   aponta para o endereço do computador na rede (ex.: `https://192.168.0.10:8443/`).
   Aceite o aviso do certificado e jogue.

Se o celular não abrir, libere a porta 8443 no firewall do Windows quando ele perguntar
(marque "Redes privadas").

## Como ligar a nuvem (uma vez, uns 10 minutos)

1. **Criar o projeto:** entre em https://supabase.com, crie uma conta e um projeto
   novo (plano gratuito, região *South America (São Paulo)*).
2. **Criar o banco:** no projeto, abra **SQL Editor**, cole todo o conteúdo de
   `supabase/schema.sql` e clique em **Run**. Antes de rodar, troque no final do
   arquivo o nome da pizzaria e as 3 letras (ex.: `'Forno a Lenha', 'FAL'`).
   O resultado mostra o **código da equipe**: guarde, é ele que libera o painel.
3. **Login sem espera (opcional):** em **Authentication → Sign In / Providers → Email**,
   desligue **Confirm email** para a equipe entrar no painel sem confirmar o e-mail.
4. **Chaves de acesso:** em **Project Settings → API**, copie o **Project URL** e a
   chave **anon public** e coloque em `config.js` (ou mande para o Claude colocar).
5. **Publicar:** em **Settings → Pages** deste repositório, escolha
   *Deploy from a branch*, branch `main`, pasta `/ (root)` e clique em **Save**.
6. **Primeiro acesso ao painel:** abra `https://mapolanski2020.github.io/pizza_ar/painel.html`,
   vá em **Criar acesso** e use o código da equipe. O primeiro a entrar vira o dono.

## Regras de segurança (no servidor)

- Cada adesivo vale 1 pizza, uma única vez, para um único celular.
- Adesivo já usado por outro celular: o jogo libera só a fase 1 e o painel registra a tentativa.
- No máximo 6 adesivos por celular por hora.
- Fases liberadas = pizzas comprovadas + 1 (máximo 10). A pontuação do jogo nunca vale prêmio.
- Pizza grátis só pelo painel, com 10 pontos, descontando os pontos e registrando quem entregou.
- Adesivo perdido pode ser cancelado pelo número impresso nele.
- O público não lê nenhuma tabela; cada pizzaria só vê os próprios clientes.

## Uma nova pizzaria

No SQL Editor do Supabase:

```sql
insert into crm.pizzerias (name, prefix) values ('Nome da Pizzaria', 'ABC')
returning join_code;
```

O dono cria o acesso no painel com esse código.

## Jogo da fase 1 (Zumbis da Pizza) e AR na mesa

`zumbi.html` coloca a casa numa superfície real, sem adesivo:

- **Android com ARCore (Chrome):** WebXR com detecção de superfície do próprio celular.
- **iPhone e Android sem ARCore:** SLAM no navegador com [AlvaAR](https://github.com/alanross/AlvaAR) (`zumbi/alva_ar.js`),
  que escaneia a mesa pela câmera; o giroscópio deixa o jogo nivelado.

Atenção: o AlvaAR é licenciado em **GPL-3.0** (`zumbi/ALVAAR-LICENSE-GPL3.txt`). Ao distribuir o jogo com ele,
o código do jogo também precisa ser disponibilizado sob GPL-3.0. Para um produto fechado, troque por uma solução
comercial ou um app nativo (ARKit/ARCore).

Modelos 3D: KayKit (Kay Lousberg), CC0.
