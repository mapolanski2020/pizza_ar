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
