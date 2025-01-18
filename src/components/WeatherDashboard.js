import React, { useState } from 'react';
import {
  Container,
  TextField,
  Button,
  Card,
  CardContent,
  Typography
} from '@mui/material';
import { styled } from '@mui/material/styles';
import axios from 'axios';

const SearchBox = styled('div')(({ theme }) => ({
  display: 'flex',
  gap: theme.spacing(2),
  marginBottom: theme.spacing(4),
}));

const WeatherInfo = styled('div')(({ theme }) => ({
  marginTop: theme.spacing(2),
}));

function WeatherDashboard() {
  const [city, setCity] = useState('');
  const [weatherData, setWeatherData] = useState(null);
  const [error, setError] = useState('');

  // Replace with your OpenWeatherMap API key
  const API_KEY = 'fae6e5780fa3cacb676d840f3270799b';
  
  const handleSearch = async () => {
    try {
      const response = await axios.get(
        `https://api.openweathermap.org/data/2.5/weather?q=${city}&appid=${API_KEY}&units=metric`
      );
      setWeatherData(response.data);
      setError('');
    } catch (err) {
      setWeatherData(null);
      setError('City not found. Please try again.');
    }
  };

  return (
    <Container sx={{ mt: 4 }} maxWidth="sm">
      <Typography variant="h4" component="h1" gutterBottom align="center">
        Weather Dashboard
      </Typography>
      
      <SearchBox>
        <TextField
          fullWidth
          value={city}
          onChange={(e) => setCity(e.target.value)}
          placeholder="Enter city name"
          variant="outlined"
          onKeyPress={(e) => {
            if (e.key === 'Enter') {
              handleSearch();
            }
          }}
        />
        <Button
          variant="contained"
          color="primary"
          onClick={handleSearch}
        >
          Search
        </Button>
      </SearchBox>

      {error && (
        <Typography color="error" align="center">
          {error}
        </Typography>
      )}

      {weatherData && (
        <Card sx={{ mt: 2 }}>
          <CardContent>
            <Typography variant="h5" component="h2">
              {weatherData.name}, {weatherData.sys.country}
            </Typography>
            <WeatherInfo>
              <Typography variant="h6">
                Temperature: {Math.round(weatherData.main.temp)}°C
              </Typography>
              <Typography variant="body1">
                Feels like: {Math.round(weatherData.main.feels_like)}°C
              </Typography>
              <Typography variant="body1">
                Weather: {weatherData.weather[0].main}
              </Typography>
              <Typography variant="body1">
                Humidity: {weatherData.main.humidity}%
              </Typography>
              <Typography variant="body1">
                Wind Speed: {weatherData.wind.speed} m/s
              </Typography>
            </WeatherInfo>
          </CardContent>
        </Card>
      )}
    </Container>
  );
}

export default WeatherDashboard;
