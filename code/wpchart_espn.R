source("https://raw.githubusercontent.com/leesharpe/nfldata/master/code/plays.R")
library(animation)

seq_fix <- function(start,end,move)
{
  if (move < 0 && start < end) return(end)
  if (move > 0 && start > end) return(end)
  return(seq(start,end,move))
}

create_wp_plot <- function(g=sample(games$game_id,1))
{

  # game_data
  game <- games %>% 
    filter(game_id == g | alt_game_id == g | espn == g)
  
  # error if no game
  if (nrow(game) == 0) stop(glue("No such game {g}"))
  
  # team logos
  report("Loading team logos")
  game <- game %>% 
    inner_join(team_logos,by=c("away_team"="team")) %>% 
    rename(away_logo=team_logo) %>% 
    inner_join(team_logos,by=c("home_team"="team")) %>% 
    rename(home_logo=team_logo)
  
  # load espn api json
  url <- glue("http://site.api.espn.com/apis/site/v2/sports/football/nfl/summary?event={game$espn}")
  api <- url %>% 
    xml2::read_html() %>%
    rvest::html_text() %>%
    jsonlite::fromJSON(flatten=TRUE)

  # espn wp
  espn_wp <- api$winprobability %>% 
    as_tibble() %>% 
    mutate(
      play_id=as.numeric(str_sub(playId,str_length(game$espn)+1)),
      pre_wp=1-lag(homeWinPercentage)-0.5*lag(tiePercentage),
      wp=1-homeWinPercentage-0.5*tiePercentage,
      wpa=wp-pre_wp
    ) %>% 
    select(play_id,wp,wpa)
  start_wp <- espn_wp %>% 
    filter(play_id == 1) %>% 
    pull(wp)
  
  # game's plays
  report(glue("Processing play data for {game$alt_game_id}"))
  game_plays <- plays %>% filter(game_id == g | alt_game_id == g)
  if (nrow(game_plays) == 0) stop("No plays for {game$alt_game_id} found")
  
  # overtime clock conversion data
  overtime <- (game_plays %>% pull(qtr) %>% max()) > 4
  if (overtime)
  {
    min_sec <- (game_plays %>% filter(qtr == 5 & play_type != "note") %>% pull(game_seconds_remaining) %>% min())
    max_sec <- (game_plays %>% filter(qtr == 5 & play_type != "note") %>% pull(game_seconds_remaining) %>% max())
  } else {
    min_sec <- 0
    max_sec <- 0
  }
  
  # grab WP data
  base_wp_data <- game_plays %>% 
    select(-wp,-wpa) %>% 
    inner_join(espn_wp,by="play_id") %>% 
    mutate(s=ifelse(qtr <= 4,game_seconds_remaining,-(max_sec-game_seconds_remaining)-1))

  # mark labels for relevant plays
  wp_data <- base_wp_data %>% 
    mutate(helped=ifelse(wpa>0,away_team,home_team),
           off_wpa=ifelse(away_team == posteam,wpa,-wpa),
           text=case_when(
             abs(wpa) > 0.1 & play_type == "no_play"
               & penalty_type == "Defensive Pass Interference" ~ glue("{penalty_team} PEN-DPI"),
             abs(wpa) > 0.1 & play_type == "no_play"
               & penalty_type == "Defensive Holding" ~ glue("{penalty_team} PEN-DHOLD"),
             abs(wpa) > 0.1 & play_type == "no_play"
               & penalty_type == "Roughing the Passer" ~ glue("{penalty_team} PEN-RTP"),
             abs(wpa) > 0.1 & play_type == "no_play"
               & penalty_type == "Unnecessary Roughness" ~ glue("{penalty_team} PEN-UR"),
             abs(wpa) > 0.1 & play_type == "no_play" ~
               glue("{penalty_team} PENALTY"),             
             play_type == "no_play" ~ glue(""), # don't act like no_plays happened
             touchdown == 1 & !is.na(kickoff_returner_player_name) ~
               glue("{kickoff_returner_player_name} KR TD"),
             touchdown == 1 & !is.na(punt_returner_player_name) ~
               glue("{punt_returner_player_name} PR TD"),
             touchdown == 1 & interception == 1 & off_wpa < 0 ~
               glue("{ifelse(interception_player_name,defteam,interception_player_name)} DEF TD"),
             touchdown == 1 & off_wpa < 0 ~
               glue("{fumble_recovery_1_player_name} DEF TD"),
             touchdown == 1 & !is.na(receiver_player_name) ~
               glue("{receiver_player_name} TD"),
             touchdown == 1 ~
               glue("{rusher_player_name} TD"),
             safety == 1 ~ glue("SAFETY"),
             field_goal_result == "made" ~ glue("{posteam} FG GOOD"),
             abs(wpa) < 0.045 ~ glue(""),  # significance cutoff
             field_goal_attempt == 1 ~ glue("{posteam} FG {toupper(field_goal_result)}"),
             interception == 1 ~
               glue("{interception_player_name} INT"),
             fumble_recovery_2_team == posteam & play_type == "punt" ~
               glue("{defteam} MUFF PUNT"),
             is.na(fumble_recovery_2_team) & fumble_recovery_1_team == posteam
               & play_type == "punt" ~ glue("{defteam} MUFF PUNT"),
             fumble_recovery_2_team == defteam & play_type != "punt" ~
               glue("{posteam} FUM LOST"),
             is.na(fumble_recovery_2_team) & fumble_recovery_1_team == defteam & play_type != "punt" ~
               glue("{posteam} FUM LOST"),
             abs(wpa) < 0.095 ~ glue(""),  # significance cutoff
             sack == 1 ~ glue("{defteam} SACK"),
             !is.na(kickoff_returner_player_name) ~
               glue("{kickoff_returner_player_name} KR"),
             !is.na(punt_returner_player_name) ~
               glue("{punt_returner_player_name} PR"),
             down == 4 & yards_gained < ydstogo ~ glue("4D STOP"),             
             !is.na(receiver_player_name) & complete_pass == 1 ~
               glue("{receiver_player_name} Catch"),
             !is.na(rusher_player_name) & incomplete_pass == 1 ~
               glue("{passer_player_name} Incomplete"),
             !is.na(rusher_player_name) ~
               glue("{rusher_player_name} Rush"),   
             TRUE ~ glue("")),
           text=ifelse(text == "","",glue("{text}\n{helped} +{abs(round(100*wpa))}%")),
           away_score=ifelse(posteam == away_team,posteam_score,defteam_score),
           home_score=ifelse(posteam == away_team,defteam_score,posteam_score)) %>% 
    select(play_id,qtr,time,s,wp,wpa,posteam,away_score,home_score,text)

  # points for plotting
  x_max <- ifelse(overtime,-(max_sec-min_sec)-1,0)
  x_lab_min <- 3600 - 250
  x_lab_max <- x_max + 250
  x_score <- 320 - x_max
    
  # determine the location of the label
  report("Preparing data for plot")
  wp_data$x_text <- NA
  wp_data$y_text <- NA
  wp_data <- wp_data %>% arrange(desc(abs(wpa)))
  for (r in which(wp_data$text != ""))
  {
    # ordered list of spots this label could go
    y_side <- wp_data$wp[r] >= 0.5
    if (y_side)
    {
      y_spots <- c(seq_fix(wp_data$wp[r]-0.1,0.05,-0.1),seq_fix(wp_data$wp[r]+0.1,0.95,0.1))
    } else {
      y_spots <- c(seq_fix(wp_data$wp[r]+0.1,0.95,0.1),seq_fix(wp_data$wp[r]-0.1,0.05,-0.1))
    }
    # iterate, see if this spot is valid
    for (i in 1:length(y_spots))
    {
      valid <- TRUE
      if (nrow(wp_data %>% filter(y_spots[i]-0.1 < wp & wp < y_spots[i]+0.1 &
                                  wp_data$s[r]-300 < s & s < wp_data$s[r]+300)) > 0)
      {
        # too close to the WP line
        valid <- FALSE
      }
      if (nrow(wp_data %>% filter(y_spots[i]-0.1 < y_text & y_text < y_spots[i]+0.1 &
                                wp_data$s[r]-600 < x_text & x_text < wp_data$s[r]+600)) > 0)
      {
        # too close to another label
        valid <- FALSE
      }
      if (valid)
      {
        # we found a spot for it, store and break loop
        wp_data$x_text[r] <- wp_data$s[r] 
        wp_data$y_text[r] <- y_spots[i]
        break
      }
    }
    # try x_spots?
    if (!valid)
    {
      x_side <- wp_data$s[r] >= 1800
      if (x_side)
      {
        x_spots <- c(seq_fix(wp_data$s[r]-400,x_lab_max,-200),
                     seq_fix(wp_data$s[r]+400,x_lab_min,200))
      } else {
        x_spots <- c(seq_fix(wp_data$s[r]+400,x_lab_min,200),
                     seq_fix(wp_data$s[r]-400,x_lab_max,-200))
      }
      for (i in 1:length(x_spots))
      {
        valid <- TRUE
        if (nrow(wp_data %>% filter(wp_data$wp[r]-0.1 < wp & wp < wp_data$wp[r]+0.1 &
                                    x_spots[i]-300 < s & s < x_spots[i]+300)) > 0)
        {
          # too close to the WP line
          valid <- FALSE
        }
        if (nrow(wp_data %>% filter(wp_data$wp[r]-0.1 < y_text & y_text < wp_data$wp[r]+0.1 &
                                    x_spots[i]-600 < x_text & x_text < x_spots[i]+600)) > 0)
        {
          # too close to another label
          valid <- FALSE
        }
        if (valid)
        {
          # we found a spot for it, stop loop
          wp_data$x_text[r] <- x_spots[i]
          wp_data$y_text[r] <- wp_data$wp[r]
          break
        }
      }
    }
    # warn about the labels not placed
    if (!valid)
    {
      warning(glue(paste("No room for ({game$alt_game_id},{wp_data$s[r]},{round(wp_data$wp[r],3)}):",
                         "{gsub('\n',' ',wp_data$text[r])}")))
    }
  }
  
  # add on WP boundaries
  first_row <- data.frame(play_id=0,qtr=1,time="15:00",s=3600,
                          wp=start_wp,wpa=NA,text=as.character(""),
                          x_text=NA,y_text=NA,away_score=0,home_score=0,
                          stringsAsFactors=FALSE)
  last_row <- data.frame(play_id=999999,qtr=max(wp_data$qtr),s=x_max-1,
                         time=ifelse(max(wp_data$qtr) >= 5,"FINAL\nOT","FINAL"),
                         wp=ifelse(game$result < 0,1,ifelse(game$result > 0,0,0.5)),
                         wpa=NA,text=as.character(""),x_text=NA,y_text=NA,
                         away_score=game$away_score,home_score=game$home_score,
                         stringsAsFactors=FALSE)
  wp_data <- wp_data %>%
    bind_rows(first_row) %>% 
    bind_rows(last_row) %>%
    arrange(play_id)
  
  # output wp_data
  print(wp_data %>% filter(text != ""),n=nrow(wp_data %>% filter(text != "")))
  
  # define function to draw a frame
  draw_frame <- function(n_sec)
  {
  
    # frame data
    frm_data <- wp_data %>% 
      filter(s >= n_sec)
    
    # output quarter changes
    if (nrow(frm_data %>% filter(qtr == max(qtr))) == 1)
    {
      report(glue("Plotting plays in quarter {max(frm_data$qtr)}"))
    }
    
    # plot
    frm_plot <- frm_data %>% 
      ggplot(aes(x=s,y=wp)) +
      theme_minimal() +
      geom_vline(xintercept=c(3600,x_max),color="#5555AA") +
      geom_segment(x=-3600,xend=-x_max,y=0.5,yend=0.5,size=0.75) +
      geom_image(x=x_score,y=0.82,image=game$away_logo,size=0.08,asp=1.5) +
      geom_image(x=x_score,y=0.18,image=game$home_logo,size=0.08,asp=1.5) +
      geom_line(color="#FF0000",size=1) +
      scale_x_continuous(trans="reverse",
                         minor_breaks=NULL,
                         labels=c("KICK\nOFF","END\nQ1","HALF\nTIME","END\nQ3",
                                  ifelse(overtime,"END\nREG","FINAL"),
                                  ifelse(overtime,"FINAL\nOT","")),
                         breaks=c(seq(3600,0,-900),ifelse(overtime,x_max,-10000)),
                         limits=c(3700,x_max-490)) +
      scale_y_continuous(labels=c(glue("{game$home_team} 100%"),
                                  glue("{game$home_team} 75%"),
                                  "50%",
                                  glue("{game$away_team} 75%"),
                                  glue("{game$away_team} 100%")),
                         breaks=c(0,0.25,0.5,0.75,1),
                         limits=c(0,1)) +
      xlab("") +
      ylab("") +
      labs(title=glue("Win Probability Chart: {game$season} Week {game$week} {game$away_team} {ifelse(game$location == 'Home','@','vs.')} {game$home_team} on {game$gameday}"),
           caption="Win Probability Data from ESPN, Play Data from nflscrapR, Visualization by @LeeSharpeNFL")
  
    # score display 
    away_score <- max(frm_data$away_score,na.rm=TRUE)
    home_score <- max(frm_data$home_score,na.rm=TRUE)
    
    # clock display
    qtr <- case_when(
      max(frm_data$qtr) == 1 ~ "1st",
      max(frm_data$qtr) == 2 ~ "2nd",
      max(frm_data$qtr) == 3 ~ "3rd",
      max(frm_data$qtr) == 4 ~ "4th",
      max(frm_data$qtr) == 5 ~ "OT",
      TRUE ~ as.character(max(frm_data$qtr))
    )
    clock <- tail(frm_data$time,1)
    clock <- ifelse(substr(clock,1,1) == "0",substr(clock,2,100),clock)
    clock <- paste0(qtr,"\n",clock)
    clock <- ifelse(grepl("FINAL",tail(frm_data$time,1)),tail(frm_data$time,1),clock)
    
    # add score and clock to plot
    frm_plot <- frm_plot + 
      annotate("text",x=-x_score,y=0.71,label=away_score,color="#0000FF",size=8) +
      annotate("text",x=-x_score,y=0.29,label=home_score,color="#0000FF",size=8) +
      annotate("text",x=-x_score,y=0.50,label=clock,color="#0000FF",size=6)
    
    # label key moments
    frm_labels <- frm_data %>% 
      filter(text != "")
    frm_plot <- frm_plot + 
      geom_point(frm_labels,mapping=aes(x=s,y=wp),
                 color="#0000FF",size=2,show.legend=FALSE) +
      geom_segment(frm_labels,mapping=aes(x=x_text,xend=s,y=y_text,yend=wp),
                   linetype="dashed",color="#0000FF",na.rm=TRUE) +
      geom_label(frm_labels,mapping=aes(x=x_text,y=y_text,label=text),
                 size=3,color="#0000FF",na.rm=TRUE)      
    
    # plot the frame
    plot(frm_plot,width=12.5,height=6.47,dpi=500)
  }
  
  
  # function to draw the game
  draw_game <- function()
  {
    lapply(wp_data$s, function(n_sec)
      { 
        draw_frame(n_sec)
      })
    report("Plotting frames for pause")
    replicate(40,draw_frame(min(wp_data$s)))
    report("Assembling plots into a GIF")
  }
  
  # animate
  saveGIF(draw_game(),interval=0.1,movie.name=glue("~/game_wp/{game$alt_game_id}.gif"))
}
